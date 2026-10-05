# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Salt, type: :model do
  describe ".current" do
    it "crea il salt del giorno al primo uso e lo riusa poi (idempotente)" do
      first = described_class.current
      second = described_class.current
      expect(second.id).to eq(first.id)
      expect(described_class.count).to eq(1)
      expect(first.value).to match(/\A[0-9a-f]{64}\z/)
    end

    it "il giorno è UTC, non il timezone applicativo (web e worker devono coincidere)" do
      # 23:30 UTC del 2 luglio = 01:30 del 3 luglio a Roma: il salt deve restare sul 2 luglio UTC.
      travel_to(Time.utc(2026, 7, 2, 23, 30)) do
        expect(described_class.current.date).to eq(Date.new(2026, 7, 2))
      end
    end

    it "giorni diversi → salt diversi" do
      today = described_class.current
      travel_to(1.day.from_now) do
        tomorrow = described_class.current
        expect(tomorrow.id).not_to eq(today.id)
        expect(tomorrow.value).not_to eq(today.value)
      end
    end
  end

  it "valida presenza e unicità della data" do
    create(:analytics_salt, date: Date.new(2026, 7, 1))
    dup = build(:analytics_salt, date: Date.new(2026, 7, 1))
    expect(dup).not_to be_valid
    expect(dup.errors[:date]).to be_present
  end
end
