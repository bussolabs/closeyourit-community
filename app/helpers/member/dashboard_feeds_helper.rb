# frozen_string_literal: true

module Member
  # The words the Dashboard card and the service page share: the last read, its failure, the arrow
  # of a change and the period it compares with. CYRA-1112
  module DashboardFeedsHelper
    ARROWS = { up: "▲", down: "▼" }.freeze
    TONE_COLORS = { good: :emerald, bad: :red, neutral: :gray }.freeze

    def dashboard_read_label(feed, state)
      case state
      when :ok then t("member.dashboards.read_ago", time: time_ago_in_words(feed.checked_at || feed.fetched_at))
      when :failed then t("member.dashboards.read_failed")
      else t("member.dashboards.never_read")
      end
    end

    # Every HTTP status the service may answer with reads the same way.
    def dashboard_error_text(feed)
      key = feed.last_error.to_s.start_with?("http_") ? "http" : feed.last_error
      t("member.dashboards.errors.#{key}", default: t("member.dashboards.errors.http"))
    end

    def dashboard_arrow(direction) = ARROWS[direction]

    def dashboard_period(period) = period && t("member.dashboards.periods.#{period}", default: period)
  end
end
