class AddEnvironmentToProjectsTokens < ActiveRecord::Migration[8.1]
  def change
    # Nullable: i token legacy (Fase 1, pre-environment) restano validi; i nuovi richiedono l'env (model).
    add_reference :projects_tokens, :environment, type: :uuid, null: true,
                  foreign_key: { to_table: :types_environments }
  end
end
