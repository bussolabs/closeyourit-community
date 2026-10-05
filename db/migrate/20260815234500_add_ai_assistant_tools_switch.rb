# frozen_string_literal: true

# Interruttore dell'assistente che LEGGE i dati usando gli attrezzi (CYRA-525).
#
# Perché una chiave nuova e non il riuso di ai_assistant_chat_enabled: sono due funzioni con costi di
# ordine diverso. L'assistente di navigazione spende una chiamata per messaggio e non tocca gli
# embedding; questo ne spende una per ogni giro di attrezzi — due o tre per una domanda normale — e
# alcuni attrezzi attivano a loro volta ricerca semantica e rerank. Volendo fermare la spesa senza
# lasciare mute anche le indicazioni sulle pagine, servono due interruttori distinti.
#
# Default true come gli altri: la migration non cambia il comportamento di un'istanza già viva.
class AddAiAssistantToolsSwitch < ActiveRecord::Migration[8.1]
  def change
    add_column :settings_global, :ai_assistant_tools_enabled, :boolean, null: false, default: true
  end
end
