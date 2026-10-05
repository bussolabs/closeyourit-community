# frozen_string_literal: true

class ReconcileAgentLimitReservationIndex < ActiveRecord::Migration[8.0]
  INDEX_NAME = "index_agents_limit_reservations_active_organization"

  def up
    return if index_exists?(:agents_limit_reservations, name: INDEX_NAME)

    add_index :agents_limit_reservations, %i[organization_id expires_at],
              where: "outcome = 'granted'", name: INDEX_NAME
  end

  def down
    # L'indice appartiene logicamente alla create migration: il rollback di questa
    # riconciliazione non deve rimuoverlo dalle installazioni che lo avevano già.
  end
end
