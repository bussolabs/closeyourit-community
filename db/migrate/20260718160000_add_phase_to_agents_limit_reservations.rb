# frozen_string_literal: true

# CYAU-91 — La fase entra nell'identità della reservation (host+phase): due fasi con lo stesso runtime/TTL
# (es. autopilot e closer_staging) NON devono collassare sulla stessa idempotency key. Colonna additiva
# nullable (le reservation legacy, se esistono, restano valide con phase nil).
class AddPhaseToAgentsLimitReservations < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_limit_reservations, :phase, :string
  end
end
