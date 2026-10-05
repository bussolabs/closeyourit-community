# frozen_string_literal: true

class MetricGroupSerializer < ApplicationSerializer
  attributes :id, :fingerprint, :title, :samples_count,
             :first_seen_at, :last_seen_at, :duration_min_ms, :duration_max_ms, :ticket_id

  attribute(:kind) { |group| group.kind }
  # CYRA-45: stato di triage, così il client CLI vede l'esito dopo un bulk resolve/ignore/reopen.
  attribute(:status) { |group| group.status }
  attribute(:promoted) { |group| group.promoted? }
  attribute(:duration_avg_ms) { |group| group.average_duration_ms }
end
