# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::RollupJob, type: :job do
  let(:monitor) { create(:uptime_monitor) }

  describe "hourly" do
    it "aggrega i ping raw dell'ora chiusa in una riga hourly (SUM + avg sugli up)" do
      travel_to Time.utc(2026, 6, 27, 12, 30) do
        hour = Time.utc(2026, 6, 27, 11)
        create(:uptime_check, monitor:, up: true,  response_time_ms: 100, checked_at: hour + 5.minutes)
        create(:uptime_check, monitor:, up: true,  response_time_ms: 200, checked_at: hour + 35.minutes)
        create(:uptime_check, monitor:, up: false, response_time_ms: nil, checked_at: hour + 50.minutes)

        described_class.perform_now("hourly")

        bucket = Uptime::Check.granularity_hourly.find_by(monitor_id: monitor.id)
        expect(bucket.checked_at).to eq(hour)
        expect(bucket.checks_total).to eq(3)
        expect(bucket.checks_up).to eq(2)
        expect(bucket.avg_response_ms).to eq(150) # (100+200)/2 sugli up
      end
    end

    it "NON rolla l'ora corrente (ancora aperta)" do
      travel_to Time.utc(2026, 6, 27, 12, 30) do
        create(:uptime_check, monitor:, checked_at: Time.utc(2026, 6, 27, 12, 10))
        described_class.perform_now("hourly")
        expect(Uptime::Check.granularity_hourly.count).to eq(0)
      end
    end

    it "è idempotente: due run = 1 riga (upsert update, ricomputo)" do
      travel_to Time.utc(2026, 6, 27, 12, 30) do
        create(:uptime_check, monitor:, up: true, response_time_ms: 100, checked_at: Time.utc(2026, 6, 27, 11, 5))
        described_class.perform_now("hourly")
        create(:uptime_check, monitor:, up: false, checked_at: Time.utc(2026, 6, 27, 11, 45))

        expect { described_class.perform_now("hourly") }
          .not_to change(Uptime::Check.granularity_hourly, :count).from(1)
        expect(Uptime::Check.granularity_hourly.first.checks_total).to eq(2)
      end
    end
  end

  describe "daily" do
    it "aggrega gli hourly del giorno chiuso (SUM + media pesata) e denormalizza gli incident" do
      travel_to Time.utc(2026, 6, 27, 2, 0) do
        day = Time.utc(2026, 6, 26)
        create(:uptime_check, :hourly, monitor:, checks_total: 60, checks_up: 60, avg_response_ms: 100, checked_at: day + 1.hour)
        create(:uptime_check, :hourly, monitor:, checks_total: 60, checks_up: 30, avg_response_ms: 200, checked_at: day + 2.hours)
        create(:uptime_incident, monitor:, started_at: day + 3.hours, resolved_at: day + 3.hours + 600.seconds)

        described_class.perform_now("daily")

        bucket = Uptime::Check.granularity_daily.find_by(monitor_id: monitor.id)
        expect(bucket.checked_at).to eq(day)
        expect(bucket.checks_total).to eq(120)
        expect(bucket.checks_up).to eq(90)
        expect(bucket.avg_response_ms).to eq(133) # (100*60 + 200*30)/90 = 133.33
        expect(bucket.incidents_count).to eq(1)
        expect(bucket.downtime_seconds).to eq(600)
      end
    end

    it "incident a cavallo di mezzanotte: conta solo i secondi caduti nel giorno" do
      travel_to Time.utc(2026, 6, 27, 2, 0) do
        day = Time.utc(2026, 6, 26)
        create(:uptime_check, :hourly, monitor:, checks_total: 60, checks_up: 60, checked_at: day + 1.hour)
        # down 25/06 23:50 → 26/06 00:20: solo i 20 min del 26 contano nel bucket del 26
        create(:uptime_incident, monitor:, started_at: day - 10.minutes, resolved_at: day + 20.minutes)

        described_class.perform_now("daily")

        bucket = Uptime::Check.granularity_daily.find_by(monitor_id: monitor.id, checked_at: day)
        expect(bucket.downtime_seconds).to eq(20 * 60)
      end
    end

    it "incident ancora aperto: down fino a fine giornata" do
      travel_to Time.utc(2026, 6, 27, 2, 0) do
        day = Time.utc(2026, 6, 26)
        create(:uptime_check, :hourly, monitor:, checks_total: 60, checks_up: 0, checked_at: day + 23.hours)
        create(:uptime_incident, monitor:, started_at: day + 23.hours, resolved_at: nil) # aperto

        described_class.perform_now("daily")

        bucket = Uptime::Check.granularity_daily.find_by(monitor_id: monitor.id, checked_at: day)
        expect(bucket.downtime_seconds).to eq(1 * 3600) # 23:00 → 24:00
      end
    end
  end
end
