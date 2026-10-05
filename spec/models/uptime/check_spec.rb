# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Check, type: :model do
  it "factory valida" do
    expect(build(:uptime_check)).to be_valid
  end

  it "up deve essere booleano esplicito (nil invalido)" do
    expect(build(:uptime_check, up: nil)).not_to be_valid
    expect(build(:uptime_check, up: false)).to be_valid
  end

  it "richiede checked_at" do
    expect(build(:uptime_check, checked_at: nil)).not_to be_valid
  end

  it "appartiene a un monitor" do
    expect(build(:uptime_check, monitor: nil)).not_to be_valid
  end

  it "trait :down (timeout senza status/response)" do
    c = build(:uptime_check, :down)
    expect(c.up).to be(false)
    expect(c.status_code).to be_nil
    expect(c.error).to eq("timeout")
  end

  describe "granularity (discriminatore)" do
    it "default = check (0)" do
      expect(build(:uptime_check).granularity).to eq("check")
      expect(build(:uptime_check)).to be_granularity_check
    end

    it "riga aggregata hourly/daily" do
      expect(build(:uptime_check, :hourly)).to be_granularity_hourly
      expect(build(:uptime_check, :daily)).to be_granularity_daily
    end
  end

  describe "validazione condizionale di up" do
    it "sul ping raw up è obbligatorio (nil invalido)" do
      expect(build(:uptime_check, up: nil)).not_to be_valid
    end

    it "su una riga aggregata up=nil è valido (nessun esito singolo)" do
      expect(build(:uptime_check, :hourly, up: nil)).to be_valid
      expect(build(:uptime_check, :daily, up: nil)).to be_valid
    end

    it "checked_at resta obbligatorio anche sugli aggregati" do
      expect(build(:uptime_check, :hourly, checked_at: nil)).not_to be_valid
    end
  end

  describe "scope raw/aggregated" do
    it ".raw solo i ping; .aggregated solo i bucket" do
      m = create(:uptime_monitor)
      ping = create(:uptime_check, monitor: m)
      hourly = create(:uptime_check, :hourly, monitor: m, checked_at: 1.hour.ago.beginning_of_hour)
      daily = create(:uptime_check, :daily, monitor: m, checked_at: 1.day.ago.beginning_of_day)

      expect(described_class.raw).to contain_exactly(ping)
      expect(described_class.aggregated).to contain_exactly(hourly, daily)
    end
  end

  describe "unicità parziale (solo aggregati)" do
    it "due ping raw allo stesso istante sono ammessi (nessuna chiave unica sul raw)" do
      m = create(:uptime_monitor)
      t = Time.current
      create(:uptime_check, monitor: m, checked_at: t)
      expect { create(:uptime_check, monitor: m, checked_at: t) }.not_to raise_error
    end

    it "due bucket aggregati con [monitor, granularity, checked_at] uguale collidono" do
      m = create(:uptime_monitor)
      at = 1.hour.ago.beginning_of_hour
      create(:uptime_check, :hourly, monitor: m, checked_at: at)
      dup = build(:uptime_check, :hourly, monitor: m, checked_at: at)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
