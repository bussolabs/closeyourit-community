# frozen_string_literal: true

# Organizzazione del token per la CLI (singleton show/update). Identità minima dell'org.
class OrganizationSerializer < ApplicationSerializer
  attributes :id, :name, :slug, :default_projects_view, :created_at, :traces_retention_days, :artifacts_retention_days, :crashes_retention_days, :session_health_retention_days, :measurements_retention_days

  # CYRA-521 — `default_space` sceglieva l'area su cui atterrare; con la sidebar unica quel concetto
  # non esiste più. Resta nel payload UN GIRO, sempre null, perché è contratto pubblico e i client
  # `cyi` già installati lo leggono: toglierlo di netto li romperebbe senza preavviso. Si rimuove col
  # prossimo bump della CLI, insieme al parametro accettato e ignorato in Cli::V1::OrganizationsController.
  def default_space = nil
end
