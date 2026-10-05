# frozen_string_literal: true

module Alerting
  # F115 — a "down" alert and its "back up" alert were two unrelated rows of the inbox. This pairs
  # them: for the down alerts on a page, when the same thing came back for the same reader. One query
  # for the whole page; the first recovery after each alert wins.
  class Recoveries
    PAIRS = {
      "uptime_down" => "uptime_up", "server_down" => "server_up",
      "server_container_down" => "server_container_up",
      "server_replication_down" => "server_replication_up", "cluster_down" => "cluster_up"
    }.freeze

    # { notification_id => recovered_at }
    def self.for(notifications)
      downs = notifications.select { |notification| PAIRS.key?(notification.event_type.to_s) }
      return {} if downs.empty?

      ups = Alerting::Notification
            .where(account_id: downs.map(&:account_id).uniq, event_type: PAIRS.values_at(*downs.map { |d| d.event_type.to_s }).uniq,
                   subject_id: downs.map(&:subject_id).uniq, created_at: downs.map(&:created_at).min..)
            .order(:created_at).pluck(:event_type, :subject_type, :subject_id, :account_id, :created_at)
      downs.each_with_object({}) do |down, recovered|
        up = ups.find do |event_type, subject_type, subject_id, account_id, at|
          event_type.to_s == PAIRS[down.event_type.to_s] && subject_type == down.subject_type &&
            subject_id == down.subject_id && account_id == down.account_id && at > down.created_at
        end
        recovered[down.id] = up.last if up
      end
    end
  end
end
