# frozen_string_literal: true

module Dashboards
  # Reads one service. One read at a time per feed, so a slow answer is not overtaken by the next round.
  class FetchFeedJob < ApplicationJob
    queue_as :uptime
    limits_concurrency to: 1, key: ->(feed_id) { "dashboards:fetch:#{feed_id}" }

    def perform(feed_id)
      feed = Feed.find_by(id: feed_id)
      return if feed.nil? || !feed.enabled?

      Feeds::Fetch.call(feed:)
    end
  end
end
