# frozen_string_literal: true

module Clusters
  # Current state of a Deployment, StatefulSet or DaemonSet. restart_marks keeps
  # [[epoch_minute, restarts]] for the last 24 hours, only for minutes with restarts (CYAG-22).
  class Workload < ApplicationRecord
    KINDS = %w[Deployment StatefulSet DaemonSet].freeze

    belongs_to :cluster, class_name: "Clusters::Cluster", inverse_of: :workloads
    belongs_to :namespace, class_name: "Clusters::Namespace", inverse_of: :workloads

    scope :present, -> { where(gone_at: nil) }

    validates :kind, inclusion: { in: KINDS }
    validates :name, presence: true

    def degraded? = ready < desired

    def degraded_for?(duration, now: Time.current)
      degraded? && degraded_since.present? && degraded_since <= now - duration
    end

    def recent_restarts(window, now: Time.current)
      since = (now - window).to_i / 60
      restart_marks.sum { |minute, count| minute > since ? count : 0 }
    end

    def restarts_24h(now: Time.current) = recent_restarts(24.hours, now:)

    # A loop that stopped restarting for CRASHLOOP_QUIET is over, even if the window still counts it.
    def crashlooping?(now: Time.current)
      last_reason == "CrashLoopBackOff" ||
        (recent_restarts(Clusters::Constants::CRASHLOOP_WINDOW, now:) >= Clusters::Constants::CRASHLOOP_RESTARTS &&
          recent_restarts(Clusters::Constants::CRASHLOOP_QUIET, now:).positive?)
    end
  end
end
