# frozen_string_literal: true

# Sezione tecnica separata del corpo semplice di una pagina KB. NULLABLE (opzionale,
# retrocompatibile con le pagine esistenti). Congelata anche nello snapshot immutabile
# (knowledge_versions) come title/body/kind. Entra nell'embedding semantico solo se valorizzata
# (vedi Knowledge::EmbeddingText) → nessun re-embed del parco esistente.
class AddTechSpecToKnowledgePagesAndVersions < ActiveRecord::Migration[8.1]
  def change
    add_column :knowledge_pages, :tech_spec, :text
    add_column :knowledge_versions, :tech_spec, :text
  end
end
