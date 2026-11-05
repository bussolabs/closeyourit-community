# frozen_string_literal: true

require "rails_helper"

RSpec.describe Instance::CheckReleaseJob do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:release) { Instance::ReleaseFeed::Release.new(version: "1.5.0", notes: []) }
  let(:advisories_url) { "https://raw.githubusercontent.com/bussolabs/closeyourit-community/advisories/advisories.json" }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
    # The release checks below are about releases: the list is down unless an example serves one.
    stub_request(:get, advisories_url).to_return(status: 404)
  end

  def self_hosted!(on = true) = stub_const("ENV", ENV.to_h.merge("CLOSEYOURIT_SELF_HOSTED" => on.to_s))

  it "does nothing outside a community install" do
    self_hosted!(false)
    allow(Instance::ReleaseFeed).to receive(:call)

    described_class.perform_now

    expect(Instance::ReleaseFeed).not_to have_received(:call)
    expect(a_request(:get, advisories_url)).not_to have_been_made
  end

  it "keeps the newer release for the notice" do
    self_hosted!
    allow(Instance::ReleaseFeed).to receive(:call).and_return(release)

    described_class.perform_now

    expect(cache.read(Instance::Update::CACHE_KEY)).to eq(release)
  end

  it "asks the releases of the channel chosen in Valhalla (CYRA-1160)" do
    self_hosted!
    Settings::Global.instance.update!(release_channel: "beta")
    allow(Instance::ReleaseFeed).to receive(:call).and_return(nil)

    described_class.perform_now

    expect(Instance::ReleaseFeed).to have_received(:call).with(current: anything, channel: "beta")
  end

  it "forgets the release once there is nothing newer" do
    self_hosted!
    cache.write(Instance::Update::CACHE_KEY, release)
    allow(Instance::ReleaseFeed).to receive(:call).and_return(nil)

    described_class.perform_now

    expect(cache.read(Instance::Update::CACHE_KEY)).to be_nil
  end

  it "keeps the previous answer when the releases cannot be read" do
    self_hosted!
    cache.write(Instance::Update::CACHE_KEY, release)
    allow(Instance::ReleaseFeed).to receive(:call).and_raise(Instance::ReleaseFeed::Error, "down")

    expect { described_class.perform_now }.not_to raise_error
    expect(cache.read(Instance::Update::CACHE_KEY)).to eq(release)
  end

  describe "the signed list of insecure versions (CYRA-1160)" do
    let(:november_second) { Time.zone.parse("2026-11-02 09:00:00") }
    let(:insecure) { [ { id: "CYI-1", fixed_in: "1.4.3" } ] }
    let(:settings) { Settings::Global.instance }

    before do
      self_hosted!
      trust_advisory_key!
      allow(Instance::ReleaseFeed).to receive(:call).and_return(nil)
      allow(Rails.logger).to receive(:warn)
    end

    def serve(body) = stub_request(:get, advisories_url).to_return(status: 200, body:)

    it "stores a verified list when none was stored" do
      serve(signed_advisories(issued_at: november_second, advisories: insecure))

      described_class.perform_now

      expect(settings.reload.security_advisories_issued_at).to eq(november_second)
      expect(settings.security_advisory_list.entries.map(&:id)).to eq(%w[CYI-1])
    end

    it "replaces the stored list with a newer signed one" do
      stored_advisories!(issued_at: november_second, advisories: insecure)
      serve(signed_advisories(issued_at: november_second + 1.day, advisories: []))

      described_class.perform_now

      expect(settings.reload.security_advisories_issued_at).to eq(november_second + 1.day)
      expect(settings.security_advisory_list.entries).to be_empty
    end

    it "drops a signed list older than the stored one" do
      stored_advisories!(issued_at: november_second, advisories: insecure)
      serve(signed_advisories(issued_at: november_second - 1.day, advisories: []))

      described_class.perform_now

      expect(settings.reload.security_advisories_issued_at).to eq(november_second)
      expect(settings.security_advisory_list.entries.map(&:id)).to eq(%w[CYI-1])
    end

    it "drops a list with a forged signature and keeps the stored one" do
      stored_advisories!(issued_at: november_second, advisories: insecure)
      serve(signed_advisories(issued_at: november_second + 1.day, advisories: [], key: RbNaCl::SigningKey.generate))

      described_class.perform_now

      expect(settings.reload.security_advisory_list.entries.map(&:id)).to eq(%w[CYI-1])
      expect(Rails.logger).to have_received(:warn).with(/kept the stored security list: the signature matches no trusted key/)
    end

    it "stores nothing and writes a note when the first list is forged" do
      serve(signed_advisories(issued_at: november_second, advisories: insecure, key: RbNaCl::SigningKey.generate))

      described_class.perform_now

      expect(settings.reload.security_advisories).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/kept the stored security list/)
    end

    it "keeps the stored list however long the source stays down" do
      stored_advisories!(issued_at: november_second, advisories: insecure)
      stub_request(:get, advisories_url).to_timeout

      travel_to(november_second + 30.days) { 3.times { described_class.perform_now } }

      expect(settings.reload.security_advisory_list.entries.map(&:id)).to eq(%w[CYI-1])
    end

    it "still checks the list when the releases cannot be read" do
      allow(Instance::ReleaseFeed).to receive(:call).and_raise(Instance::ReleaseFeed::Error, "down")
      serve(signed_advisories(issued_at: november_second, advisories: insecure))

      described_class.perform_now

      expect(settings.reload.security_advisories).to be_present
    end
  end
end
