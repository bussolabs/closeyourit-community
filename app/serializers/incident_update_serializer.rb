# frozen_string_literal: true

# Step della timeline narrata di un incident uptime (canale CLI). phase = fase raggiunta con lo step;
# body = testo dello step (opzionale).
class IncidentUpdateSerializer < ApplicationSerializer
  attributes :id, :incident_id, :phase, :body, :created_at
end
