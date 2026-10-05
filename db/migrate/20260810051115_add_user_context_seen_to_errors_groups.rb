# frozen_string_literal: true

# CYRA-380: fatto storico "il gruppo ha MAI ricevuto il contesto utente", per distinguere «mai
# tracciato» da «zero utenti distinti» in modo robusto. Non si può derivare da users_count: quello è
# un lower-bound deliberato che Errors::Split#recount! ricalcola dagli eventi conservati e
# Errors::Merge fa col max — dopo split+potatura può tornare a zero pur avendo tracciato. Il flag è
# monotòno (una volta true, resta true) e immune a split/prune.
class AddUserContextSeenToErrorsGroups < ActiveRecord::Migration[8.1]
  def up
    add_column :errors_groups, :user_context_seen, :boolean, default: false, null: false

    # Backfill: chi ha già contato almeno un utente ha sicuramente ricevuto il contesto utente.
    execute("UPDATE errors_groups SET user_context_seen = TRUE WHERE users_count > 0")
  end

  def down
    remove_column :errors_groups, :user_context_seen
  end
end
