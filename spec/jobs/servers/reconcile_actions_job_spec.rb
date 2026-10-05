# frozen_string_literal: true

require "rails_helper"

# CYRA-809 — la rete per l'host che non torna MAI: senza questo giro, un server che sparisce per
# sempre lascia la sua azione "in corso" e il suo posto occupato, perché la riconciliazione
# dell'agent al ritorno presuppone un ritorno.
RSpec.describe Servers::ReconcileActionsJob, type: :job do
  it "gira sulla coda :maintenance dei controlli" do
    expect(described_class.new.queue_name).to eq("maintenance")
  end

  it "chiude le azioni rimaste a metà e ne ritorna il numero" do
    host = create(:server_host)
    grace = Servers::Constants::ACTION_ORPHAN_AFTER_SECONDS
    action = create(:server_action, host:, organization: host.organization, status: :running,
                    started_at: 3.hours.ago, expires_at: 2.hours.ago,
                    lease_expires_at: (grace + 60).seconds.ago)

    expect(described_class.perform_now).to eq(1)
    expect(action.reload).to be_status_interrupted
  end

  it "non fa nulla quando non c'è niente da chiudere" do
    expect(described_class.perform_now).to eq(0)
  end

  it "è schedulato nel recurring di produzione" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")

    expect(schedule).to include(
      "reconcile_server_actions" => a_hash_including("class" => described_class.name, "queue" => "maintenance")
    )
  end
end
