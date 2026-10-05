# frozen_string_literal: true

require "rails_helper"
require "rake"

# CYRA-846 — le regole di avviso di default nascono con l'organizzazione (Organizations::Provision):
# un tipo di avviso aggiunto dopo resta senza regola, e Alerting::Evaluate lo genera e lo butta via.
# Questo comando ripara le organizzazioni già esistenti.
RSpec.describe "bin/rails alerting:install_defaults", :silence_output do
  let(:task_name) { "alerting:install_defaults" }

  before do
    load Rails.root.join("lib/tasks/alerting_defaults.rake").to_s unless Rake::Task.task_defined?(task_name)
  end

  it "esiste" do
    expect(Rake::Task.task_defined?(task_name)).to be(true)
  end

  it "installa sulle organizzazioni esistenti le regole di default che mancano" do
    organization = create(:organization)
    mancante = Alerting::Rule.where(organization_id: organization.id, event_type: :vulnerability_new)
    mancante.delete_all

    expect { Rake::Task[task_name].execute }.to change { mancante.count }.from(0).to(1)
  end

  it "è idempotente: rieseguito non aggiunge niente" do
    create(:organization)
    Rake::Task[task_name].execute

    expect { Rake::Task[task_name].execute }.not_to change(Alerting::Rule, :count)
  end
end
