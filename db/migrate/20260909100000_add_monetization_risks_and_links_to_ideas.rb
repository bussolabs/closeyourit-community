# frozen_string_literal: true

# CYRA-845 — monetizzazione, rischi ed evoluzioni erano commenti.
#
# Nei commenti delle idee reali non c'era discussione: c'erano dati (come si monetizza, quali
# rischi, come evolve la proposta), scritti lì perché l'idea non aveva dove metterli. Mescolare
# i due usi rende il thread illeggibile a chi deve discutere. Due colonne di testo per ciò che è
# un fatto dell'idea; una tabella di collegamenti per ciò che è un'altra idea (evoluzione, oppure
# parente alla pari), perché un'evoluzione merita voti e discussione propri.
class AddMonetizationRisksAndLinksToIdeas < ActiveRecord::Migration[8.1]
  def change
    add_column :ideas_ideas, :monetization, :text,
               comment: "Come l'idea si ripaga (Markdown). Fatto dell'idea, non un commento"
    add_column :ideas_ideas, :risks, :text,
               comment: "Rischi e vincoli noti (Markdown). Fatto dell'idea, non un commento"

    create_table :ideas_links, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :source, type: :uuid, null: false, foreign_key: { to_table: :ideas_ideas, on_delete: :cascade }
      t.references :target, type: :uuid, null: false, foreign_key: { to_table: :ideas_ideas, on_delete: :cascade }
      t.integer :kind, null: false, default: 0,
                comment: "0 evolution: source evolve target (un solo livello) · 1 related: parenti alla pari"
      t.timestamps
    end
    # Una sola relazione per coppia ordinata; la simmetria dei related è garantita dal modello.
    add_index :ideas_links, %i[source_id target_id], unique: true
    # Un'evoluzione ha UN solo padre.
    add_index :ideas_links, :source_id, unique: true, where: "kind = 0", name: "index_ideas_links_one_parent_per_source"
  end
end
