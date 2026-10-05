# frozen_string_literal: true

module SessionHealth
  module Retention
    def self.for(project, global_days: :unset)
      Monitoring::Retention.for(project, key: :session_health, global_days: global_days)
    end
  end
end
