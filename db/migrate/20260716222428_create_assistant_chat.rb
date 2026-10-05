# frozen_string_literal: true

# Chat dell'assistente help, per-utente e per-organizzazione (isolamento tenant come Todos::List:
# possesso di un account dentro un'org, nessun RBAC). Una conversazione raccoglie i messaggi scambiati
# con l'assistente; last_message_at è denormalizzato per ordinare la lista "riprendi conversazioni"
# senza join. I messaggi portano un ruolo (user/assistant) e uno status (la risposta dell'assistente
# nasce `streaming` vuota e viene finalizzata a `complete`/`failed` dal job che consuma lo stream Gemini).
# organization_id è denormalizzato anche sui messaggi (come chat_messages) per lo scoping tenant.
class CreateAssistantChat < ActiveRecord::Migration[8.1]
  def change
    create_table :assistant_conversations, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }

      t.string   :title
      t.datetime :last_message_at
    end

    # Lista "riprendi conversazioni": le mie conversazioni nell'org per attività recente.
    add_index :assistant_conversations, %i[account_id organization_id last_message_at]

    create_table :assistant_messages, id: :uuid do |t|
      t.timestamps

      t.references :conversation, type: :uuid, null: false,
                   foreign_key: { to_table: :assistant_conversations, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }

      t.integer :role,   null: false                 # enum { user: 0, assistant: 1 }
      t.integer :status, null: false, default: 0     # enum { streaming: 0, complete: 1, failed: 2 }
      t.text    :content                             # nullo mentre streaming; presente per user e assistant complete
      t.string  :error_code                          # valorizzato su status failed (messaggio reso da i18n)
    end

    # Timeline cronologica dei messaggi di una conversazione.
    add_index :assistant_messages, %i[conversation_id created_at]
  end
end
