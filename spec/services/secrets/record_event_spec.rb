# frozen_string_literal: true

require "rails_helper"

# L'unico posto da cui nasce una riga del registro del vault. Due proprietà lo definiscono: non deve
# MAI rompere l'operazione che sta registrando (un audit che fallisce non può impedire una lettura),
# e solo gli ACCESSI possono svegliare qualcuno — le mutazioni hanno già i loro avvisi.
RSpec.describe Secrets::RecordEvent, type: :service do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:, code: "production") }
  let(:actor) { create(:account) }

  it "scrive la riga con l'organizzazione presa dal progetto" do
    event = described_class.call(action: "read", project:, environment:, actor:, name: "API_KEY",
                                 metadata: { count: 3 }, channel: "cli")

    expect(event).to be_persisted
    expect(event).to have_attributes(action: "read", organization:, project:, environment:, actor:,
                                     name: "API_KEY", channel: "cli")
    expect(event.metadata).to eq({ "count" => 3 })
  end

  it "il minimo indispensabile è l'azione e il progetto" do
    event = described_class.call(action: "synced", project:)

    expect(event).to be_persisted
    expect(event.environment).to be_nil
    expect(event.actor).to be_nil
    expect(event.channel).to be_nil
  end

  it "è fire-and-forget: un'azione che non esiste torna nil, non solleva, e lascia detto perché" do
    allow(Rails.logger).to receive(:warn)

    expect { expect(described_class.call(action: "telepatia", project:)).to be_nil }
      .not_to change(Secrets::Event, :count)
    expect(Rails.logger).to have_received(:warn).with(/Secrets audit event failed/)
  end

  it "un guasto dell'audit non ferma chi lo stava scrivendo" do
    allow(Secrets::Event).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "db giù")

    expect { described_class.call(action: "read", project:, channel: "web") }.not_to raise_error
    expect(Alerting::EvaluateJob).not_to have_been_enqueued
  end

  describe "gli avvisi sugli accessi (CYRA-77)" do
    it "una lettura dal web fa scattare la valutazione delle regole" do
      event = described_class.call(action: "read", project:, environment:, actor:, channel: "web")

      expect(Alerting::EvaluateJob)
        .to have_been_enqueued.with(hash_including(event_type: "secret_read", subject_type: "Secrets::Event",
                                                   subject_id: event.id, project_id: project.id,
                                                   environment_id: environment.id))
    end

    it "un tentativo rifiutato dal web avvisa con un tipo suo" do
      described_class.call(action: "denied", project:, environment:, actor:, channel: "web")

      expect(Alerting::EvaluateJob).to have_been_enqueued.with(hash_including(event_type: "secret_denied"))
    end

    # `cyi run` legge il vault a ogni avvio di un processo: avvisare su quelle letture spegnerebbe
    # l'attenzione di chi riceve gli avvisi, e allora passerebbe inosservata anche quella che conta.
    it "le letture dal terminale restano registrate ma non svegliano nessuno" do
      expect(described_class.call(action: "read", project:, channel: "cli")).to be_persisted
      expect(Alerting::EvaluateJob).not_to have_been_enqueued
    end

    it "senza canale non si avvisa: non sapere da dove arriva una lettura non è una ragione per allarmare" do
      described_class.call(action: "read", project:, environment:)

      expect(Alerting::EvaluateJob).not_to have_been_enqueued
    end

    it "le mutazioni non passano di qui: hanno già i loro avvisi" do
      %w[set deleted imported synced override_set override_deleted].each do |action|
        described_class.call(action:, project:, environment:, actor:, channel: "web")
      end

      expect(Secrets::Event.count).to eq(6)
      expect(Alerting::EvaluateJob).not_to have_been_enqueued
    end
  end
end
