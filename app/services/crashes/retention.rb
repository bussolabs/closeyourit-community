# frozen_string_literal: true

module Crashes
  module Retention
    def self.for(project, global_days: :unset)
      Monitoring::Retention.for(project, key: :crashes, global_days: global_days)
    end
  end
end
