# frozen_string_literal: true

require "digest"

module Ingest
  # Partition-local indexes cannot serialize delivery of the same event across arrival months.
  module EventLock
    class Busy < ActiveRecord::ActiveRecordError; end

    def self.acquire!(project_id:, event_id:, domain:)
      key = Digest::SHA256.digest([ domain, project_id, event_id ].join("\u0000")).unpack1("q>")
      connection = ApplicationRecord.connection
      bind = ActiveRecord::Relation::QueryAttribute.new("event_lock_key", key, ActiveRecord::Type::Integer.new(limit: 8))
      acquired = connection.select_value("SELECT pg_try_advisory_xact_lock($1)", "Event identity lock", [ bind ])
      raise Busy, "Event identity is being admitted" unless acquired
    end
  end
end
