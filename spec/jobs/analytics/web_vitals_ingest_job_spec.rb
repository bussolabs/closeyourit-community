# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::WebVitalsIngestJob, type: :job do
  let(:project) { create(:project) }

  def misura
    { "event_id" => SecureRandom.uuid, "metric" => "lcp", "value" => 2_400,
      "hostname" => "acme.example", "path" => "/", "occurred_at" => Time.current.iso8601 }
  end

  it "persiste il batch" do
    described_class.perform_now(project_id: project.id, context: { "device_type" => "mobile" },
                                payload: [ misura ])

    expect(Analytics::WebVital.count).to eq(1)
  end

  # Un progetto cancellato fra la richiesta e l'esecuzione del lavoro non è un guasto: le misure di
  # un progetto che non c'è più non interessano a nessuno, e far fallire il job le rimetterebbe in
  # coda all'infinito.
  it "un progetto cancellato nel frattempo non fa fallire il lavoro" do
    expect do
      described_class.perform_now(project_id: SecureRandom.uuid, context: {}, payload: [ misura ])
    end.not_to raise_error
    expect(Analytics::WebVital.count).to be_zero
  end
end
