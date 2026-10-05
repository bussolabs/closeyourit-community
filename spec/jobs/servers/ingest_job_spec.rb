# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::IngestJob, type: :job do
  let(:payload) { JSON.parse(Rails.root.join("spec/fixtures/servers/agent_payload.json").read) }

  # CYRA-850: corsia propria, non la `ingest` condivisa con le metriche di ogni app monitorata. Il
  # ritardo di un sample diventa un falso allarme «macchina caduta», quello di una metrica no.
  it "gira sulla corsia riservata all'ingest dei server" do
    expect(described_class.new.queue_name).to eq("servers_ingest")
  end

  it "delega a Servers::Ingest::Record con l'host risolto" do
    host = create(:server_host)
    expect(Servers::Ingest::Record).to receive(:call).with(host: host, payload: payload)

    described_class.perform_now(host_id: host.id, payload: payload)
  end

  it "host sparito → no-op" do
    expect(Servers::Ingest::Record).not_to receive(:call)

    described_class.perform_now(host_id: SecureRandom.uuid, payload: payload)
  end

  it "host revocato nel frattempo → no-op" do
    host = create(:server_host, :revoked)
    expect(Servers::Ingest::Record).not_to receive(:call)

    described_class.perform_now(host_id: host.id, payload: payload)
  end
end
