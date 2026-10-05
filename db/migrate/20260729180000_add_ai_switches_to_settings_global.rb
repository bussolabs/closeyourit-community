# frozen_string_literal: true

# Interruttori per-servizio delle funzioni AI, sulla riga singola di configurazione globale.
#
# Default **true** per costruzione: la migration non deve cambiare il comportamento di un'istanza
# già viva: chi non tocca nulla continua come prima. Lo spegnimento è un atto esplicito del god.
class AddAiSwitchesToSettingsGlobal < ActiveRecord::Migration[8.1]
  def change
    change_table :settings_global, bulk: true do |t|
      t.boolean :ai_agent_gate_enabled, null: false, default: true
      t.boolean :ai_assistant_chat_enabled, null: false, default: true
      t.boolean :ai_triage_enabled, null: false, default: true
      t.boolean :ai_embeddings_enabled, null: false, default: true
      t.boolean :ai_ticket_composition_enabled, null: false, default: true
      t.boolean :ai_dataset_predictions_enabled, null: false, default: true
    end
  end
end
