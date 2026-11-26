# frozen_string_literal: true

require "rails_helper"

# CYRA-1144 — il giro giornaliero che riapre le vulnerabilità ignorate arrivate alla scadenza.
RSpec.describe Vulnerabilities::ReopenExpiredIgnoresJob do
  it "delega al servizio" do
    allow(Vulnerabilities::ReopenExpiredIgnores).to receive(:call).and_return(Result.ok(0))

    described_class.perform_now

    expect(Vulnerabilities::ReopenExpiredIgnores).to have_received(:call)
  end

  it "è pianificato ogni giorno in produzione, sulla coda di manutenzione" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    entry = schedule.dig("production", "reopen_expired_vulnerability_ignores")

    expect(entry).to include("class" => described_class.name, "queue" => "maintenance",
                             "schedule" => "every day at 7am")
    expect(described_class.new.queue_name).to eq("maintenance")
  end
end
