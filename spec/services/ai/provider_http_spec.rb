# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::ProviderHttp do
  let(:uri) { URI.parse("https://llm.example.com/v1/chat/completions") }

  describe ".build" do
    it "connects to a trusted address without resolving it" do
      allow(NetworkGuard).to receive(:resolved_public_address)

      http = described_class.build(uri, untrusted: false, open_timeout: 5, read_timeout: 20)

      expect(NetworkGuard).not_to have_received(:resolved_public_address)
      expect([ http.address, http.use_ssl?, http.ipaddr ]).to eq([ "llm.example.com", true, nil ])
    end

    it "pins the public address of an untrusted host, so it is not resolved again" do
      allow(NetworkGuard).to receive(:resolved_public_address).with("llm.example.com").and_return("93.184.216.34")

      http = described_class.build(uri, untrusted: true, open_timeout: 5, read_timeout: 20)

      expect(http.ipaddr).to eq("93.184.216.34")
    end

    it "refuses an untrusted host that resolves inside the internal network" do
      allow(NetworkGuard).to receive(:resolved_public_address).with("llm.example.com").and_return(nil)

      expect { described_class.build(uri, untrusted: true, open_timeout: 5, read_timeout: 20) }
        .to raise_error(described_class::BlockedAddress)
    end
  end
end
