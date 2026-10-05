# frozen_string_literal: true

module Teams
  # Prefisso tabella del dominio: Teams::Team → "teams_teams" senza self.table_name esplicito
  # (rules/rails/models.md). L'eponimo Team è ammesso (come Accounts::Account).
  def self.table_name_prefix = "teams_"
end
