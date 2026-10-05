# frozen_string_literal: true

# Stato di partecipazione di un account a una conversazione: quando ha letto (last_read_at → non-letti)
# e se l'ha silenziata (muted_at). Per i DM le 2 righe SONO anche l'ACL (accesso = essere partecipante);
# per i canali sono create lazy alla prima apertura e servono SOLO per stato (l'accesso è relazionale).
# organization_id denormalizzato (come Ticketing::Subscription) per blindare lo scoping tenant.
class CreateChatParticipants < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_participants, id: :uuid do |t|
      t.timestamps

      t.references :conversation, type: :uuid, null: false,
                   foreign_key: { to_table: :chat_conversations, on_delete: :cascade }
      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }

      t.datetime :last_read_at
      t.datetime :muted_at
    end

    add_index :chat_participants, %i[conversation_id account_id], unique: true
  end
end
