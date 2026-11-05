# frozen_string_literal: true

require "rails_helper"

RSpec.describe Instance::Advisories do
  let(:issued_at) { Time.zone.parse("2026-11-02 10:00:00") }
  let(:advisories) { [ { id: "CYI-2026-01", introduced: "1.2.0", fixed_in: "1.4.3", summary: "Session fixation" } ] }

  before { trust_advisory_key! }

  describe ".verify" do
    it "reads a list signed with a trusted key" do
      list = described_class.verify(signed_advisories(issued_at:, advisories:))

      expect(list.issued_at).to eq(issued_at)
      expect(list.entries.map(&:fixed_in)).to eq(%w[1.4.3])
    end

    it "refuses a list signed with another key" do
      body = signed_advisories(issued_at:, advisories:, key: RbNaCl::SigningKey.generate)

      expect { described_class.verify(body) }.to raise_error(described_class::Invalid, /no trusted key/)
    end

    it "refuses a list changed after it was signed" do
      envelope = JSON.parse(signed_advisories(issued_at:, advisories:))
      envelope["payload"] = Base64.strict_encode64({ issued_at: issued_at.iso8601, advisories: [] }.to_json)

      expect { described_class.verify(envelope.to_json) }.to raise_error(described_class::Invalid)
    end

    it "refuses every list while no key is trusted" do
      stub_const("App::SelfHosted::ADVISORIES_PUBLIC_KEYS", [])

      expect { described_class.verify(signed_advisories(issued_at:, advisories:)) }.to raise_error(described_class::Invalid)
    end

    it "accepts the new key next to the old one during a rotation" do
      new_key = RbNaCl::SigningKey.generate
      stub_const("App::SelfHosted::ADVISORIES_PUBLIC_KEYS", [ advisory_signing_key, new_key ].map { |key| Base64.strict_encode64(key.verify_key.to_bytes) })

      expect(described_class.verify(signed_advisories(issued_at:, advisories:, key: new_key)).entries.size).to eq(1)
    end

    it "refuses something that is not a list" do
      expect { described_class.verify("<html>") }.to raise_error(described_class::Invalid)
      expect { described_class.verify({ payload: "!!", signature: "" }.to_json) }.to raise_error(described_class::Invalid)
    end

    it "refuses a signed list with a version in another shape" do
      body = signed_advisories(issued_at:, advisories: [ { id: "X", fixed_in: "1.4.3/../../evil" } ])

      expect { described_class.verify(body) }.to raise_error(described_class::Invalid)
    end
  end

  describe "#finding" do
    subject(:list) do
      described_class.new(issued_at:, entries: [
        described_class::Entry.new(id: "A", introduced: "1.2.0", fixed_in: "1.4.3", summary: ""),
        described_class::Entry.new(id: "B", introduced: nil, fixed_in: "1.4.5", summary: "")
      ])
    end

    it "names the version that closes every advisory the running one is in" do
      finding = list.finding("v1.4.2")

      expect(finding.fixed_in).to eq("1.4.5")
      expect(finding.ids).to eq(%w[A B])
    end

    it "is nil once the running version is the one to install" do
      expect(list.finding("1.4.5")).to be_nil
    end

    it "leaves out versions before the advisory was introduced" do
      expect(list.finding("1.1.0").ids).to eq(%w[B])
    end

    it "treats a beta as older than its stable" do
      expect(list.finding("1.4.5-beta.1").fixed_in).to eq("1.4.5")
    end

    it "says nothing for a version it cannot read" do
      expect(list.finding("unknown")).to be_nil
    end
  end
end
