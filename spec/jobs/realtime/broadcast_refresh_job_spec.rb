# frozen_string_literal: true

require "rails_helper"

# Ramo TRAILING del throttle di Metrics/Errors::Broadcast (CYRA-41): a fine finestra emette un
# page-refresh Turbo sullo stream passato (String tenant-prefissata), così lo stato finale del burst
# viene mostrato anche quando gli eventi si esauriscono dentro la finestra del leading.
RSpec.describe Realtime::BroadcastRefreshJob, type: :job do
  it "emette un page-refresh Turbo (action=refresh) sullo stream passato" do
    stream = Realtime::Streams.metrics(create(:organization))

    expect { described_class.perform_now(stream) }
      .to have_broadcasted_to(stream).with(a_string_including('action="refresh"'))
  end

  it "gira sulla coda :ingest" do
    expect(described_class.new.queue_name).to eq("ingest")
  end
end
