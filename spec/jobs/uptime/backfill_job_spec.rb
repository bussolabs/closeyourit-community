# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::BackfillJob, type: :job do
  it "genera hourly e daily su tutta la storia dei ping raw (idempotente)" do
    monitor = create(:uptime_monitor)
    travel_to Time.utc(2026, 6, 27, 12) do
      create(:uptime_check, monitor:, up: true,  response_time_ms: 100, checked_at: Time.utc(2026, 6, 20, 10, 5))
      create(:uptime_check, monitor:, up: false, checked_at: Time.utc(2026, 6, 20, 10, 40))
      create(:uptime_check, monitor:, up: true,  response_time_ms: 150, checked_at: Time.utc(2026, 6, 25, 8, 15))

      described_class.perform_now

      expect(Uptime::Check.granularity_hourly.count).to eq(2) # ore 20/06 10:00 e 25/06 08:00
      expect(Uptime::Check.granularity_daily.count).to eq(2)  # giorni 20/06 e 25/06

      day20 = Uptime::Check.granularity_daily.find_by(checked_at: Time.utc(2026, 6, 20))
      expect(day20.checks_total).to eq(2)
      expect(day20.checks_up).to eq(1)

      expect { described_class.perform_now }.not_to change(Uptime::Check.aggregated, :count)
    end
  end

  it "no-op se non ci sono ping raw" do
    expect { described_class.perform_now }.not_to change(Uptime::Check, :count)
  end
end
