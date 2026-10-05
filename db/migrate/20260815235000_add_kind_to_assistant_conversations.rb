# frozen_string_literal: true

# Distingue le conversazioni dei DUE assistenti (CYRA-526).
#
# Portano lo stesso nome ma sono cose diverse: quello del sito dice dove andare e ha il divieto
# esplicito di parlare dei dati, quello raggiungibile da fuori li legge e non conosce le pagine.
# Finché condividevano la tabella senza discriminatore, l'app poteva aprire — e cancellare — un
# thread nato nel sito, e la storia di un assistente sarebbe finita nel prompt dell'altro, che ha
# regole opposte.
#
# `help` come default perché tutte le conversazioni esistenti vengono da lì.
class AddKindToAssistantConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :assistant_conversations, :kind, :integer, null: false, default: 0
    add_index :assistant_conversations, [ :account_id, :organization_id, :kind ],
              name: "index_assistant_conversations_on_owner_and_kind"
  end
end
