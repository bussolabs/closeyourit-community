# frozen_string_literal: true

require "rails_helper"

# Un linguaggio che esce dal supporto è una scadenza, non un guasto: si avvisa e basta. La scelta di
# NON aprire un ticket da soli è deliberata — aggiornare la versione di un linguaggio è un progetto,
# e metterlo in backlog di nascosto vorrebbe dire decidere al posto di chi lo deve pianificare.
RSpec.describe Vulnerabilities::NotifyRuntimes, type: :service do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account:, organization:, role: :owner) }
  end
  let(:project) { create(:project, organization:) }

  before do
    owner
    Alerting::Rules::InstallDefaults.call(organization:)
  end

  it "avvisa chi vede il progetto che il supporto è finito" do
    status = create(:vulnerability_runtime_status, :eol, project:, name: "ruby")

    result = perform_enqueued_jobs { described_class.call(statuses: [ status ]) }

    expect(result).to be_ok
    notification = Alerting::Notification.find_by(account: owner, via: :in_app, event_type: :runtime_eol)
    expect(notification).to be_present
    expect(notification.title).to include("ruby")
    expect(notification.project).to eq(project)
  end

  it "non apre nessun ticket: la scadenza si pianifica, non si mette in coda da sola" do
    status = create(:vulnerability_runtime_status, :eol, project:)

    expect { perform_enqueued_jobs { described_class.call(statuses: [ status ]) } }
      .not_to change(Ticketing::Ticket, :count)
  end

  it "un avviso per ogni runtime, ognuno legato al suo progetto" do
    primo = create(:vulnerability_runtime_status, :eol, project:, name: "ruby")
    altro_progetto = create(:project, organization:)
    secondo = create(:vulnerability_runtime_status, :ending_soon, project: altro_progetto, name: "nodejs")

    result = described_class.call(statuses: [ primo, secondo ])

    expect(result.value).to eq(2)
    expect(Alerting::EvaluateJob).to have_been_enqueued.twice
    expect(Alerting::EvaluateJob)
      .to have_been_enqueued.with(hash_including(event_type: "runtime_eol", subject_id: primo.id,
                                                 project_id: project.id, environment_id: nil))
    expect(Alerting::EvaluateJob)
      .to have_been_enqueued.with(hash_including(subject_id: secondo.id, project_id: altro_progetto.id))
  end

  # L'avviso non è legato a un ambiente: un linguaggio fuori supporto lo è ovunque giri.
  it "dichiara il soggetto per esteso, così chi valuta la regola sa cosa sta guardando" do
    status = create(:vulnerability_runtime_status, :ending_soon, project:)

    described_class.call(statuses: [ status ])

    expect(Alerting::EvaluateJob)
      .to have_been_enqueued.with(hash_including(subject_type: "Vulnerabilities::RuntimeStatus"))
  end

  it "senza runtime in allarme non sveglia nessuno" do
    result = described_class.call(statuses: [])

    expect(result).to be_ok
    expect(result.value).to eq(0)
    expect(Alerting::EvaluateJob).not_to have_been_enqueued
  end

  it "un singolo stato passato da solo vale come una lista di uno" do
    status = create(:vulnerability_runtime_status, :eol, project:)

    expect(described_class.call(statuses: status).value).to eq(1)
    expect(Alerting::EvaluateJob).to have_been_enqueued.once
  end
end
