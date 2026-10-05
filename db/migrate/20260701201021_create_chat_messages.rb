# frozen_string_literal: true

# Messaggio di una conversazione. author nullify: il messaggio sopravvive alla cancellazione dell'autore
# (thread integro, render "utente eliminato"), coerente coi metadati "creato-da" del progetto. Soft
# delete via deleted_at (render "messaggio eliminato" senza rompere la timeline). Allegati via
# ActiveStorage (has_many_attached :files). organization_id denormalizzato per scoping tenant.
class CreateChatMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_messages, id: :uuid do |t|
      t.timestamps

      t.references :conversation, type: :uuid, null: false,
                   foreign_key: { to_table: :chat_conversations, on_delete: :cascade }
      t.references :author, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }

      t.text     :body
      t.datetime :deleted_at
    end

    add_index :chat_messages, %i[conversation_id created_at]
  end
end
