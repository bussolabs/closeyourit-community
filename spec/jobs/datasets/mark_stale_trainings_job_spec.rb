# frozen_string_literal: true

require "rails_helper"

# CYRA-791 — il giro periodico che chiude gli addestramenti rimasti orfani di un processo morto.
RSpec.describe Datasets::MarkStaleTrainingsJob do
  it "gira sulla corsia dei controlli: dura secondi e serve solo se parte in orario" do
    expect(described_class.new.queue_name).to eq("maintenance")
  end

  it "delega al service e restituisce quanti ne ha chiusi" do
    create(:dataset_training, status: :running,
                              heartbeat_at: (Datasets::Constants::TRAINING_STALE_AFTER + 1.minute).ago)

    expect(described_class.perform_now).to eq(1)
  end

  it "è nei giri periodici della produzione, altrimenti non lo lancia nessuno" do
    schedule = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")
    entry = schedule.values.find { |value| value["class"] == described_class.name }

    expect(entry).to be_present
    expect(entry["queue"]).to eq("maintenance")
  end
end
