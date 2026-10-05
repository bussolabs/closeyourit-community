# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::DispatchChecksJob, type: :job do
  include ActiveJob::TestHelper

  it "accoda un CheckJob per ogni monitor scaduto, non per i recenti/pausati" do
    travel_to(Time.utc(2026, 6, 26, 12)) do
      overdue = create(:uptime_monitor, interval_seconds: 60, last_checked_at: 2.minutes.ago)
      create(:uptime_monitor, interval_seconds: 60, last_checked_at: 5.seconds.ago)   # recente
      create(:uptime_monitor, :paused, interval_seconds: 60, last_checked_at: nil)     # pausato

      expect { described_class.perform_now }
        .to have_enqueued_job(Uptime::CheckJob).with(overdue.id).exactly(:once)
    end
  end
end
