# frozen_string_literal: true

# CYRA-852 — l'owner riceve i suoi avvisi in un gruppo Telegram diviso per argomento.
#
# Un gruppo per organizzazione, collegato dall'owner. Gli argomenti nascono al primo avviso che
# li riguarda e il loro numero si salva qui, per chiave (critical, servers, tickets…). Il codice di
# collegamento porta l'organizzazione quando serve a collegare un gruppo e non la chat personale.
class CreateAlertingTelegramGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :alerting_telegram_groups, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :organization, type: :uuid, null: false, index: { unique: true },
                                  foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :account, type: :uuid, null: false,
                             foreign_key: { to_table: :accounts, on_delete: :cascade },
                             comment: "L'owner che ha collegato il gruppo: riceve lì i suoi avvisi"
      t.string :chat_id, null: false
      t.string :title
      t.jsonb :topics, null: false, default: {},
                       comment: "Chiave dell'argomento (critical o gruppo del catalogo) → message_thread_id"
      t.timestamps
    end

    add_reference :accounts_telegram_link_codes, :organization, type: :uuid, null: true,
                  foreign_key: { to_table: :organizations, on_delete: :cascade },
                  comment: "Presente = il codice collega il gruppo con argomenti di questa organizzazione"
  end
end
