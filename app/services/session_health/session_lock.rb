# frozen_string_literal: true

require "digest"

module SessionHealth
  # Serializes writers of the same session (ingest and pruning) without holding the project row.
  # Keys are taken in ascending key order, so two transactions sharing sessions never deadlock,
  # even when two sids collide on one key. Waits instead of failing: the holder is a short write.
  module SessionLock
    def self.acquire!(project_id:, sids:)
      keys = keys(project_id: project_id, sids: sids)
      return if keys.empty?
      bind = ActiveRecord::Relation::QueryAttribute.new("session_lock_keys", "{#{keys.join(",")}}", ActiveRecord::Type::String.new)
      ApplicationRecord.connection.select_all("SELECT pg_advisory_xact_lock(key)::text FROM unnest($1::bigint[]) WITH ORDINALITY AS locks(key, position) ORDER BY position", "Session identity lock", [ bind ])
    end

    # Unique and ascending: the one order every transaction locks in.
    def self.keys(project_id:, sids:)
      Array(sids).compact.map { |sid| Digest::SHA256.digest([ "session_health", project_id, sid.downcase ].join("\u0000")).unpack1("q>") }.uniq.sort
    end
  end
end
