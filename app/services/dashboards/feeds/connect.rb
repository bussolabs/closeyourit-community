# frozen_string_literal: true

module Dashboards
  module Feeds
    # Connects a project to its service's Open Dashboard: saves the address and issues a new key.
    # The key comes back in the Result once, to be put in the service's vault as OPEN_DASHBOARD_TOKEN.
    class Connect < ApplicationService
      TOKEN_PREFIX = "od_"
      TOKEN_LENGTH = 40

      def initialize(project:, url:)
        @project = project
        @url = url.to_s.strip
      end

      def call
        token = "#{TOKEN_PREFIX}#{SecureRandom.alphanumeric(TOKEN_LENGTH)}"
        feed = @project.dashboard_feed || @project.build_dashboard_feed
        feed.assign_attributes(url: @url, token:, enabled: true)
        # A different service: the old numbers and the old failure are not about it.
        feed.assign_attributes(payload: nil, fetched_at: nil, checked_at: nil, last_error: nil) if feed.url_changed?
        feed.save!

        Result.ok({ feed:, token: })
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-DASHBOARD-001", details: e.record.errors.as_json))
      end
    end
  end
end
