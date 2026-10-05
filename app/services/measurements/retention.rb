# frozen_string_literal: true

module Measurements
  module Retention
    def self.for(project, global_days: :unset)
      Monitoring::Retention.for(project, key: :measurements, global_days: global_days)
    end
  end
end
