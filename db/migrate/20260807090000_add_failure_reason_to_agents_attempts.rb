# frozen_string_literal: true

class AddFailureReasonToAgentsAttempts < ActiveRecord::Migration[8.1]
  def change
    # Motivo del fallimento riportato dalla macchina quando la sessione muore (CYRA-282): finora
    # `failed` era nell'enum e in TERMINAL_STATUSES ma nessun percorso lo scriveva, quindi un guasto
    # restava indistinguibile da una macchina spenta. Nullable: i tentativi terminati in altro modo e
    # tutto lo storico non hanno un motivo. Text (non string): il traceback/riassunto dell'errore può
    # superare i limiti di una colonna varchar.
    add_column :agents_attempts, :failure_reason, :text
  end
end
