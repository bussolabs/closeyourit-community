# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Announcement, type: :model do
  it "factory valida" do
    expect(build(:uptime_announcement)).to be_valid
  end

  it "richiede un messaggio" do
    expect(build(:uptime_announcement, message: "  ")).not_to be_valid
  end

  it "espone i livelli" do
    expect(described_class.levels.keys).to eq(%w[info maintenance warning])
  end

  describe "validazione finestra" do
    it "ends_at deve seguire starts_at" do
      a = build(:uptime_announcement, starts_at: Time.utc(2026, 6, 26, 12), ends_at: Time.utc(2026, 6, 26, 11))
      expect(a).not_to be_valid
      expect(a.errors[:ends_at]).to be_present
    end

    it "estremi nil ammessi (finestra illimitata)" do
      expect(build(:uptime_announcement, starts_at: nil, ends_at: nil)).to be_valid
    end
  end

  describe "#live?" do
    it "spento → mai live" do
      expect(build(:uptime_announcement, :inactive).live?).to be(false)
    end

    it "attivo senza finestra → sempre live" do
      expect(build(:uptime_announcement, starts_at: nil, ends_at: nil).live?).to be(true)
    end

    it "confine start: 1s prima non live, all'istante e dopo live" do
      start = Time.utc(2026, 6, 26, 12)
      a = build(:uptime_announcement, starts_at: start, ends_at: nil)
      expect(a.live?(start - 1)).to be(false)
      expect(a.live?(start)).to be(true)
      expect(a.live?(start + 1)).to be(true)
    end

    it "confine end: all'istante live, 1s dopo non live" do
      finish = Time.utc(2026, 6, 26, 14)
      a = build(:uptime_announcement, starts_at: nil, ends_at: finish)
      expect(a.live?(finish)).to be(true)
      expect(a.live?(finish + 1)).to be(false)
    end
  end
end
