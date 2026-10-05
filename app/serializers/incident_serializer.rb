# frozen_string_literal: true

# Incident uptime (canale CLI). phase = detected/investigating/fixing/monitoring/resolved (enum string,
# nil se non narrato). parent_id valorizzato sulle finestre unificate (figli di un primary raggruppato).
class IncidentSerializer < ApplicationSerializer
  attributes :id, :monitor_id, :parent_id, :phase, :started_at, :resolved_at, :created_at
end
