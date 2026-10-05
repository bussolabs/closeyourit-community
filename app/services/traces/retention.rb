# frozen_string_literal: true

module Traces
  module Retention
    def self.for(project, global_days: :unset)
      Monitoring::Retention.for(project, key: :traces, global_days: global_days)
    end
  end
end
