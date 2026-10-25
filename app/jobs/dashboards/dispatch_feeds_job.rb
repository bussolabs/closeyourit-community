# frozen_string_literal: true

module Dashboards
  # Every 15 minutes: one read per enabled feed, each in its own job so a slow service delays only itself.
  class DispatchFeedsJob < ApplicationJob
    queue_as :uptime

    def perform
      Feed.enabled.find_each { |feed| FetchFeedJob.perform_later(feed.id) }
    end
  end
end
