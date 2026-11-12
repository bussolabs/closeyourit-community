# frozen_string_literal: true

require "rails_helper"

# CYRA-201: prima di questo job nessuna voce di recurring.yml riguardava Agents::*, quindi una lavorazione
# morta non veniva chiusa da nessuno.
RSpec.describe Agents::MarkStaleAttemptsJob, type: :job do
  it "gira sulla coda :maintenance" do
    expect(described_class.new.queue_name).to eq("maintenance")
  end

  it "chiude le lavorazioni ferme e ne ritorna il numero" do
    organization = create(:organization)
    host = create(:agent_host, organization:)
    workflow = create(:agent_workflow, organization:)
    attempt = create(:agent_attempt, workflow:, organization:, host:,
                                     external_run_id: "run-1", started_at: 3.hours.ago)
    create(:agent_lease, :host_first, host:, organization:, ticket: workflow.ticket,
                                      run_id: "run-1", expires_at: 2.hours.ago)

    expect(described_class.perform_now).to eq(1)
    expect(attempt.reload).to be_status_stale
  end

  # CYRA-1113 — una riga per chiusura, confrontabile con il registro della macchina.
  it "scrive nel registro una riga per ogni tentativo chiuso, con ticket, fase, esecuzione e motivo" do
    organization = create(:organization)
    host = create(:agent_host, organization:)
    workflow = create(:agent_workflow, organization:)
    create(:agent_attempt, workflow:, organization:, host:, phase: "triage",
                           external_run_id: "run-1", started_at: 3.hours.ago)
    create(:agent_lease, :host_first, host:, organization:, ticket: workflow.ticket,
                                      run_id: "run-1", expires_at: 2.hours.ago)
    allow(Rails.logger).to receive(:info)

    described_class.perform_now

    expect(Rails.logger).to have_received(:info).with(
      a_string_including("ticket=#{workflow.ticket.code}", "phase=triage", "run=run-1",
                         "reason=lease_expired at=", "minutes=60")
    )
  end

  # Il giro ogni 5 minuti non tocca una valutazione lunga finché la sua prenotazione (1 ora) è valida.
  it "lascia in corso una valutazione di 50 minuti con la prenotazione valida per 10 giri" do
    organization = create(:organization)
    host = create(:agent_host, organization:)
    workflow = create(:agent_workflow, organization:)
    started_at = Time.current
    attempt = create(:agent_attempt, workflow:, organization:, host:, phase: "triage",
                                     external_run_id: "run-lunga", started_at:)
    create(:agent_lease, :host_first, host:, organization:, ticket: workflow.ticket,
                                      run_id: "run-lunga", expires_at: started_at + 1.hour)

    giri = (1..10).map do |giro|
      travel_to(started_at + (5 * giro).minutes) { described_class.perform_now }
    end

    expect(giri).to all(eq(0))
    expect(attempt.reload).to be_status_running
  end

  it "non fa nulla quando non ci sono orfani" do
    expect(described_class.perform_now).to eq(0)
  end

  it "è schedulato nel recurring di produzione" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")

    expect(schedule).to include(
      "mark_stale_agent_attempts" => a_hash_including("class" => described_class.name, "queue" => "maintenance")
    )
  end
end
