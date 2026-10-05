# frozen_string_literal: true

class PreserveHostLimitReservations < ActiveRecord::Migration[8.0]
  def up
    change_column_null :agents_limit_reservations, :host_id, true
    remove_foreign_key :agents_limit_reservations, column: :host_id
    add_foreign_key :agents_limit_reservations, :agents_hosts,
                    column: :host_id, on_delete: :nullify
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Le reservation possono riferirsi a host eliminati e non sono ricostruibili"
  end
end
