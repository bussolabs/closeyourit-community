# frozen_string_literal: true

class PreserveAgentLimitReservations < ActiveRecord::Migration[8.0]
  def up
    unless column_exists?(:agents_limit_reservations, :agent_id)
      add_reference :agents_limit_reservations, :agent,
                    type: :uuid, null: true, index: true
    end

    change_column_null :agents_limit_reservations, :agent_id, true
    if foreign_key_exists?(:agents_limit_reservations, column: :agent_id)
      remove_foreign_key :agents_limit_reservations, column: :agent_id
    end
    add_foreign_key :agents_limit_reservations, :agents_agents,
                    column: :agent_id, on_delete: :nullify
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Le reservation possono riferirsi ad agenti eliminati e non sono ricostruibili"
  end
end
