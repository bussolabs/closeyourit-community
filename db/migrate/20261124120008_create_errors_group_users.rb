# frozen_string_literal: true

# CYRA-1241 — le persone già viste da ogni errore. `users_count` saliva quando l'utente non compariva
# fra le occorrenze CONSERVATE: dopo la potatura chi tornava era contato di nuovo, e due primi eventi
# simultanei dello stesso utente contavano due. L'elenco vive accanto al gruppo e muore solo con lui
# (cascade sulla FK): la potatura degli eventi non lo tocca. L'indice unico è ciò che decide chi è
# nuovo, anche in concorrenza.
#
# Riempimento dello storico dagli eventi conservati (a blocchi, non ferma l'ingest) → dopo il deploy
# lanciare una volta:
#   bin/rails runner 'Errors::BackfillGroupUsersJob.perform_later'
class CreateErrorsGroupUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :errors_group_users, id: :uuid do |t|
      t.references :group, type: :uuid, null: false, index: false,
                           foreign_key: { to_table: :errors_groups, on_delete: :cascade }
      t.string :user_hash, null: false
      t.datetime :created_at, null: false
    end
    add_index :errors_group_users, %i[group_id user_hash], unique: true
  end
end
