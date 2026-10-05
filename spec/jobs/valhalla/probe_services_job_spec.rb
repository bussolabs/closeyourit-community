# frozen_string_literal: true

require "rails_helper"

RSpec.describe Valhalla::ProbeServicesJob, type: :job do
  include_context "valhalla service health cache"

  # Nessuna chiamata di rete reale in questo spec: ENV pulita → ProbeServices segna tutto
  # "unconfigured" senza toccare Net::HTTP (WebMock bloccherebbe comunque qualunque richiesta reale).
  around do |example|
    keys = %w[AI_API_KEY EMBED_BASE_URL AI_BASE_URL
              TELEGRAM_BOT_TOKEN GH_APP_ID GH_APP_PRIVATE_KEY]
    original = keys.index_with { |key| ENV[key] }
    keys.each { |key| ENV.delete(key) }
    example.run
    original.each { |key, value| ENV[key] = value }
  end

  it "delega la sonda a Valhalla::ProbeServices" do
    expect(Valhalla::ProbeServices).to receive(:call).and_call_original

    described_class.perform_now

    expect(Rails.cache.read(Valhalla::ProbeServices::CACHE_KEY)).to be_present
  end

  it "gira sulla coda maintenance" do
    expect(described_class.new.queue_name).to eq("maintenance")
  end
end
