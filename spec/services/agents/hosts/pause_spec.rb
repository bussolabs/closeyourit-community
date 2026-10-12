# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Hosts::Pause do
  let(:organization) { create(:organization) }
  let(:actor) { create(:account) }
  let(:host) { create(:agent_host, organization:) }
  let(:now) { Time.zone.local(2026, 10, 12, 14, 40) }

  it "pauses the machine without an end and records who did it" do
    result = described_class.call(host:, actor:, now:)

    expect(result).to be_ok
    expect(host.reload).to have_attributes(paused_at: now, paused_by: actor, paused_until: nil, pause_reason: nil)
    expect(host.paused?(now: now + 30.days)).to be(true)
  end

  it "ends the pause by itself when a duration is chosen" do
    described_class.call(host:, actor:, duration: "4h", now:)

    expect(host.reload.paused_until).to eq(now + 4.hours)
    expect(host.paused?(now: now + 3.hours)).to be(true)
    expect(host.paused?(now: now + 4.hours)).to be(false)
  end

  it "keeps the reason written by the person" do
    described_class.call(host:, actor:, reason: "  Updating the operating system  ", now:)

    expect(host.reload.pause_reason).to eq("Updating the operating system")
  end

  it "replaces a previous pause" do
    described_class.call(host:, actor: create(:account), duration: "1h", reason: "first", now:)
    described_class.call(host:, actor:, now: now + 10.minutes)

    expect(host.reload).to have_attributes(paused_by: actor, paused_until: nil, pause_reason: nil)
  end

  it "refuses an unknown duration and leaves the machine working" do
    result = described_class.call(host:, actor:, duration: "forever", now:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-AGENT-011")
    expect(host.reload).not_to be_paused
  end

  it "refuses a reason longer than the limit" do
    result = described_class.call(host:, actor:, reason: "x" * (Agents::Constants::PAUSE_REASON_MAX + 1), now:)

    expect(result).to be_err
    expect(host.reload).not_to be_paused
  end
end

RSpec.describe Agents::Hosts::Resume do
  let(:host) { create(:agent_host, paused_at: 1.hour.ago, paused_by: create(:account), paused_until: 1.hour.from_now, pause_reason: "maintenance") }

  it "clears the pause so the machine takes work again" do
    result = described_class.call(host:)

    expect(result).to be_ok
    expect(host.reload).to have_attributes(paused_at: nil, paused_by: nil, paused_until: nil, pause_reason: nil)
    expect(host).not_to be_paused
  end
end
