# frozen_string_literal: true

# Conversazione di chat, per-organizzazione (isolamento tenant come Todos::List). Tre forme via `kind`:
# - direct: DM 1:1 tra due membri; identità canonica in `direct_key` (SHA degli account-id ordinati),
#   unica per org → una sola conversazione per coppia.
# - project / team: canale persistente legato a un contesto (contextable polimorfico Projects::Project
#   o Teams::Team), unico per contesto. L'ACCESSO ai canali è relazionale (VisibleScope / team
#   membership), NON via righe chat_participants (quelle tengono solo lo stato letto/muto).
# last_message_at è denormalizzato per ordinare la lista senza join. created_by nullify: un canale
# auto-creato sopravvive alla cancellazione di chi l'ha aperto.
class CreateChatConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_conversations, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.integer  :kind, null: false, default: 0
      t.string   :contextable_type
      t.uuid     :contextable_id
      t.string   :direct_key
      t.string   :title
      t.datetime :last_message_at
    end

    # Un solo canale per contesto (progetto/team) dentro l'org.
    add_index :chat_conversations, %i[organization_id contextable_type contextable_id],
              unique: true, where: "contextable_id IS NOT NULL",
              name: "index_chat_conversations_on_context"
    # Un solo DM per coppia (direct_key canonica) dentro l'org.
    add_index :chat_conversations, %i[organization_id direct_key],
              unique: true, where: "direct_key IS NOT NULL",
              name: "index_chat_conversations_on_direct_key"
    # Ordinamento lista conversazioni (attività recente).
    add_index :chat_conversations, %i[organization_id last_message_at]
  end
end
