# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::IngestJob do
  it "persiste il sample via Record" do
    project = create(:project)
    described_class.perform_now(project_id: project.id, payload: {
      "kind" => "slow_query", "sample_id" => "x", "duration_ms" => 10,
      "sql" => "SELECT 1", "occurred_at" => Time.current.iso8601
    })
    expect(project.metric_samples.count).to eq(1)
  end

  it "scarta senza errore se il progetto non esiste" do
    expect do
      described_class.perform_now(project_id: SecureRandom.uuid, payload: {})
    end.not_to raise_error
  end

  it "logga (non scarta in silenzio) quando Record rifiuta il campione (kind invalido)" do
    project = create(:project)
    expect(Rails.logger).to receive(:warn).with(/R422-METRIC-002/)
    described_class.perform_now(project_id: project.id, payload: { "kind" => "bogus", "duration_ms" => 5 })
  end

  # CYRA-43: il controller accoda UN job con l'intero array → il job batcha tutti i campioni.
  it "persiste l'intero array in un solo job (batch)" do
    project = create(:project)
    payloads = %w[a b c].map do |id|
      { "kind" => "slow_query", "sample_id" => id, "duration_ms" => 10,
        "sql" => "SELECT 1", "occurred_at" => Time.current.iso8601 }
    end
    described_class.perform_now(project_id: project.id, payload: payloads)
    expect(project.metric_samples.count).to eq(3)
    expect(project.metric_groups.sole.samples_count).to eq(3)
  end

  it "logga gli scartati aggregati per codice quando l'array contiene campioni invalidi" do
    project = create(:project)
    expect(Rails.logger).to receive(:warn).with(/R422-METRIC-002/)
    described_class.perform_now(project_id: project.id, payload: [
      { "kind" => "slow_query", "sample_id" => "ok", "duration_ms" => 5, "sql" => "SELECT 1", "occurred_at" => Time.current.iso8601 },
      { "kind" => "bogus", "sample_id" => "ko", "duration_ms" => 5 }
    ])
    expect(project.metric_samples.count).to eq(1)
  end
end
