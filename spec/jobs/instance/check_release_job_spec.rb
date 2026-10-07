# frozen_string_literal: true

require "rails_helper"

RSpec.describe Instance::CheckReleaseJob do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:release) { Instance::ReleaseFeed::Release.new(version: "1.5.0", notes: []) }

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def self_hosted!(on = true) = stub_const("ENV", ENV.to_h.merge("CLOSEYOURIT_SELF_HOSTED" => on.to_s))

  it "does nothing outside a community install" do
    self_hosted!(false)
    allow(Instance::ReleaseFeed).to receive(:call)

    described_class.perform_now

    expect(Instance::ReleaseFeed).not_to have_received(:call)
  end

  it "keeps the newer release for the notice" do
    self_hosted!
    allow(Instance::ReleaseFeed).to receive(:call).and_return(release)

    described_class.perform_now

    expect(cache.read(Instance::Update::CACHE_KEY)).to eq(release)
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
end
