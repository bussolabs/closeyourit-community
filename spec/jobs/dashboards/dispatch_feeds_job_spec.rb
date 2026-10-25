# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboards::DispatchFeedsJob, type: :job do
  it "queues one read per enabled feed" do
    on = create(:dashboards_feed)
    create(:dashboards_feed, enabled: false)

    expect { described_class.perform_now }
      .to have_enqueued_job(Dashboards::FetchFeedJob).with(on.id).exactly(:once)
  end

  it "runs every 15 minutes on the uptime queue in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
      .fetch("production").fetch("dispatch_dashboard_feeds")

    expect(entry).to include("class" => "Dashboards::DispatchFeedsJob", "queue" => "uptime",
                             "schedule" => "every 15 minutes")
  end
end
