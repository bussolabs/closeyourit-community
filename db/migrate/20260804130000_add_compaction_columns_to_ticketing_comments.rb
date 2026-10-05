# frozen_string_literal: true

# Colonne di supporto alla compattazione dei commenti storici (CYRA-222).
#
# `original_body` NON è ridondanza: è ciò che rende l'operazione reversibile anche dove il
# classificatore sbaglia. Il testo integrale finisce sì in una versione del resoconto, ma solo per i
# commenti classificati come resoconto — per tutti gli altri questa colonna è l'unica copia. Ed è
# anche l'audit di una riscrittura fatta da un modello: senza, "il riassunto è infedele" non sarebbe
# nemmeno verificabile.
#
# `compacted_at` è la chiave di idempotenza della seconda passata: un commento già compattato non
# torna mai a un LLM, nemmeno se il rake viene rilanciato.
class AddCompactionColumnsToTicketingComments < ActiveRecord::Migration[8.1]
  def change
    add_column :ticketing_comments, :original_body, :text
    add_column :ticketing_comments, :compacted_at, :datetime

    # Predicato della passata B (`compacted_at IS NULL AND length(body) > 240`): parziale, perché a
    # regime la stragrande maggioranza delle righe è compattata e l'indice deve restare piccolo.
    add_index :ticketing_comments, :compacted_at, where: "compacted_at IS NULL"
  end
end
