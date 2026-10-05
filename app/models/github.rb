# frozen_string_literal: true

module Github
  # Prefisso tabella del dominio: Github::Installation → "github_installations", Github::Repository
  # → "github_repositories", ecc. (rules/rails/models.md). Namespace isolato per l'integrazione
  # GitHub (App unica installata sull'org: repo↔progetto 1:1, binding tag→release, branch/PR↔ticket).
  def self.table_name_prefix = "github_"
end
