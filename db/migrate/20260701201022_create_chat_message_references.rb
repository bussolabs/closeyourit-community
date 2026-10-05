# frozen_string_literal: true

# Risorsa taggata in un messaggio (la feature distintiva della chat): referable polimorfico verso
# Projects::Project / Ticketing::Ticket / Errors::Group / Metrics::Group / Logs::Entry / Uptime::Monitor.
# Persistita SOLO se la risorsa è nell'intersezione delle visibilità dei partecipanti (validato nel
# service Chat::References::Parse). organization_id denormalizzato = scoping tenant. NON è un FK reale
# (polimorfico su più tabelle); l'integrità è nel model (referable stessa org). Unica per (messaggio,
# risorsa): niente tag doppio.
class CreateChatMessageReferences < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_message_references, id: :uuid do |t|
      t.timestamps

      t.references :message, type: :uuid, null: false,
                   foreign_key: { to_table: :chat_messages, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }

      t.string :referable_type, null: false
      t.uuid   :referable_id, null: false
    end

    add_index :chat_message_references, %i[referable_type referable_id]
    add_index :chat_message_references, %i[message_id referable_type referable_id],
              unique: true, name: "index_chat_message_references_unique"
  end
end
