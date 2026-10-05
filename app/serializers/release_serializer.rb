# frozen_string_literal: true

class ReleaseSerializer < ApplicationSerializer
  attributes :id, :version, :environment, :sha, :build_time, :first_event_at, :last_event_at, :events_count, :created_at
end
