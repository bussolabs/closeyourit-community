class AddStakeholdersToIdeasIdeas < ActiveRecord::Migration[8.1]
  # «Per chi può essere utile»: lista libera di tag per-idea (text[]), stesso pattern di
  # Projects::Document#tags. Indice GIN per il filtro overlap (&&) futuro.
  def change
    add_column :ideas_ideas, :stakeholders, :text, array: true, default: [], null: false
    add_index :ideas_ideas, :stakeholders, using: :gin
  end
end
