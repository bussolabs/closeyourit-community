# frozen_string_literal: true

module Artifacts
  module Retention
    def self.for(project, global_days: :unset)
      Monitoring::Retention.for(project, key: :artifacts, global_days: global_days)
    end
  end
end
