# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::PruneJob, type: :job do
  before { Settings::Global.instance.update!(uptime_retention_days: 730) }

  it "pota raw/hourly (costanti fisse) e il daily (default di sistema) oltre il loro cutoff, senza toccare le righe entro soglia" do
    monitor = create(:uptime_monitor)
    travel_to Time.utc(2026, 6, 27, 12) do
      old_raw  = create(:uptime_check, monitor:, checked_at: 3.days.ago - 1.second)
      keep_raw = create(:uptime_check, monitor:, checked_at: 3.days.ago + 1.second)
      old_hourly  = create(:uptime_check, :hourly, monitor:, checked_at: 90.days.ago - 1.hour)
      keep_hourly = create(:uptime_check, :hourly, monitor:, checked_at: 90.days.ago + 1.hour)
      old_daily  = create(:uptime_check, :daily, monitor:, checked_at: 730.days.ago - 1.day)
      keep_daily = create(:uptime_check, :daily, monitor:, checked_at: 730.days.ago + 1.day)

      described_class.perform_now

      expect(Uptime::Check.exists?(old_raw.id)).to be(false)
      expect(Uptime::Check.exists?(keep_raw.id)).to be(true)
      expect(Uptime::Check.exists?(old_hourly.id)).to be(false)
      expect(Uptime::Check.exists?(keep_hourly.id)).to be(true)
      expect(Uptime::Check.exists?(old_daily.id)).to be(false)
      expect(Uptime::Check.exists?(keep_daily.id)).to be(true)
    end
  end

  it "rispetta l'override per-progetto sul daily (nearest-wins), lasciando raw/hourly invariati" do
    project = create(:project).tap { |p| p.update!(uptime_retention_days: 365) }
    monitor = create(:uptime_monitor, project:)
    travel_to Time.utc(2026, 6, 27, 12) do
      old_daily = create(:uptime_check, :daily, monitor:, checked_at: 366.days.ago)
      kept_raw = create(:uptime_check, monitor:, checked_at: 2.days.ago) # entro raw (3g), non toccato

      described_class.perform_now

      expect(Uptime::Check.exists?(old_daily.id)).to be(false)
      expect(Uptime::Check.exists?(kept_raw.id)).to be(true)
    end
  end

  it "applica la retention dell'org al daily quando il progetto non ha override" do
    org = create(:organization).tap { |o| o.update!(uptime_retention_days: 100) }
    project = create(:project, organization: org)
    monitor = create(:uptime_monitor, project:)
    travel_to Time.utc(2026, 6, 27, 12) do
      old_daily = create(:uptime_check, :daily, monitor:, checked_at: 101.days.ago)
      fresh_daily = create(:uptime_check, :daily, monitor:, checked_at: 10.days.ago)

      described_class.perform_now

      expect(Uptime::Check.exists?(old_daily.id)).to be(false)
      expect(Uptime::Check.exists?(fresh_daily.id)).to be(true)
    end
  end

  it "non tocca gli uptime_incidents" do
    monitor = create(:uptime_monitor)
    incident = create(:uptime_incident, monitor:, started_at: 800.days.ago, resolved_at: 799.days.ago)

    described_class.perform_now

    expect(Uptime::Incident.exists?(incident.id)).to be(true)
  end
end
