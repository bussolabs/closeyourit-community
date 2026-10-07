# frozen_string_literal: true

require "rails_helper"

RSpec.describe Instance::Update do
  subject(:update) { described_class.new(dir:, current: "v1.4.2", cache:, now:) }

  let(:dir) { Pathname(Dir.mktmpdir) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:now) { Time.zone.parse("2026-10-06 12:00:00") }
  let(:actor) { instance_double(Accounts::Account, id: 7) }

  before do
    stub_const("ENV", ENV.to_h.merge("CLOSEYOURIT_SELF_HOSTED" => "true"))
    dir.join("inbox").mkpath
    dir.join("status").mkpath
  end

  after { FileUtils.rm_rf(dir) }

  def release!(version = "1.5.0") = cache.write(described_class::CACHE_KEY, Instance::ReleaseFeed::Release.new(version:, notes: []))
  def heartbeat!(at = now - 30.seconds) = dir.join("status/heartbeat").write(at.to_i.to_s)
  def status!(state, target) = dir.join("status/status.json").write({ state:, target:, from: "1.4.2", backup: "b.dump" }.to_json)

  describe "#available" do
    it "is the cached release when it is newer than the running one" do
      release!

      expect(update.available.version).to eq("1.5.0")
    end

    it "is nil once the install runs that release" do
      release!("1.4.2")

      expect(update.available).to be_nil
    end

    it "is nil outside a community install" do
      stub_const("ENV", ENV.to_h.merge("CLOSEYOURIT_SELF_HOSTED" => "false"))
      release!

      expect(update.available).to be_nil
    end
  end

  describe "#helper_alive?" do
    it "is true with a recent heartbeat" do
      heartbeat!

      expect(update).to be_helper_alive
    end

    it "is false with a heartbeat older than five minutes" do
      heartbeat!(now - 6.minutes)

      expect(update).not_to be_helper_alive
    end

    it "is false when the host never wrote one" do
      expect(update).not_to be_helper_alive
    end
  end

  describe "#state" do
    before { release! }

    it "is queued while the request waits for the host" do
      dir.join("inbox/request").write("1.5.0\n")

      expect(update.state).to eq(:queued)
    end

    it "is running while the host updates" do
      status!("running", "1.5.0")

      expect(update.state).to eq(:running)
    end

    it "is failed when the update to the available release went back" do
      status!("failed", "1.5.0")

      expect(update.state).to eq(:failed)
      expect(update.status.backup).to eq("b.dump")
    end

    it "forgets a failure about another release" do
      status!("failed", "1.4.9")

      expect(update.state).to be_nil
    end

    it "is done when the running version is the one the host installed" do
      status!("done", "1.4.2")
      File.utime((now - 1.hour).to_time, (now - 1.hour).to_time, dir.join("status/status.json"))

      expect(update.state).to eq(:done)
    end

    it "stops saying done a day later" do
      status!("done", "1.4.2")
      File.utime((now - 2.days).to_time, (now - 2.days).to_time, dir.join("status/status.json"))

      expect(update.state).to be_nil
    end
  end

  describe "#request!" do
    before do
      release!
      heartbeat!
    end

    it "leaves the cached version for the host" do
      expect(update.request!(actor:)).to eq("1.5.0")
      expect(dir.join("inbox/request").read).to eq("1.5.0\n")
      expect(dir.join("inbox").children.map { |path| path.basename.to_s }).to eq([ "request" ])
    end

    it "refuses without a newer release" do
      cache.clear

      expect { update.request!(actor:) }.to raise_error(described_class::NotRequestable)
    end

    it "refuses when the host does not answer" do
      heartbeat!(now - 1.hour)

      expect { update.request!(actor:) }.to raise_error(described_class::NotRequestable)
    end

    it "refuses a second request while one runs" do
      status!("running", "1.5.0")

      expect { update.request!(actor:) }.to raise_error(described_class::NotRequestable)
    end
  end
end
