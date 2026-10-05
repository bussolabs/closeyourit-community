# frozen_string_literal: true

class AddCertificationToAgentsHosts < ActiveRecord::Migration[8.1]
  def change
    change_table :agents_hosts, bulk: true do |t|
      t.datetime :certified_at, null: true
      t.references :certified_by, type: :uuid, null: true,
                                  foreign_key: { to_table: :accounts, on_delete: :nullify }
    end
  end
end
