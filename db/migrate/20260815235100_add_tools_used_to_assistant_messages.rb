# frozen_string_literal: true

# Gli attrezzi che l'assistente ha usato per comporre una risposta (CYRA-526).
#
# Non è telemetria: è ciò che rende la risposta verificabile. "Ho guardato i progetti e i ticket"
# dice a chi legge su cosa si fonda il numero, e un principio del prodotto è che i dati siano
# l'interfaccia — una risposta senza le sue fonti chiede di essere creduta sulla parola.
#
# Vuoto per i messaggi dell'utente e per quelli dell'assistente del sito, che attrezzi non ne usa.
class AddToolsUsedToAssistantMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :assistant_messages, :tools_used, :jsonb, null: false, default: []
  end
end
