# frozen_string_literal: true

# CYRA-654 — «non oggi» non aveva dove essere scritto. Chi apriva la home trovava sempre la stessa
# decisione in testa: l'unico modo per non vederla era deciderla, e una decisione presa per
# togliersela davanti è peggio di una rimandata.
#
# La chiave è la stringa "famiglia:uuid" con cui la coda nomina una card (Home::Feed::Item#key), non
# una FK: le quattro famiglie vivono in quattro tabelle diverse e una colonna polimorfa per ognuna
# vorrebbe dire quattro nullable che si escludono a vicenda.
class CreateHomeDeferrals < ActiveRecord::Migration[8.1]
  def change
    create_table :home_deferrals, id: :uuid do |t|
      t.references :account, null: false, type: :uuid,
                             foreign_key: { to_table: :accounts, on_delete: :cascade }, index: false
      t.references :organization, null: false, type: :uuid,
                                  foreign_key: { to_table: :organizations, on_delete: :cascade },
                                  index: false
      t.string :card_key, null: false
      t.datetime :until_at, null: false
      t.timestamps
    end

    # Rimandare due volte la stessa card è lo stesso gesto ripetuto, non due rimandi: l'unicità
    # rende l'upsert la scrittura naturale e toglie di mezzo il caso «quale dei due vale».
    add_index :home_deferrals, %i[account_id card_key], unique: true,
              name: "index_home_deferrals_on_account_and_card"
    # La lettura della home è sempre «i miei rimandi ancora validi».
    add_index :home_deferrals, %i[account_id until_at], name: "index_home_deferrals_live"
    add_index :home_deferrals, :organization_id
  end
end
