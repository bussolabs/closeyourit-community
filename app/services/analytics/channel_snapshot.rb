# frozen_string_literal: true

module Analytics
  # CYRA-738 — la fotografia del traffico servita dai due canali a token: montaggio unico di
  # Analytics::Query (le aggregazioni) e Analytics::Snapshot (l'envelope). I due controller lo
  # facevano ciascuno per conto proprio, ricopiando anche l'elenco dei filtri ammessi.
  #
  # Sta qui e non dentro Snapshot perché Snapshot riceve una Query già costruita: lo usano anche la
  # dashboard e la pagina pubblica, che la costruiscono con parametri propri (periodo della toolbar,
  # visite di controllo incluse o no). Quello che i due canali a token condividono è il montaggio.
  class ChannelSnapshot < ApplicationService
    # `filters` arriva grezzo dai parametri della richiesta: l'allowlist è dentro Analytics::Query
    # (FILTERABLE), che tiene le chiavi ammesse e scarta i valori vuoti. Un posto solo, quello dove
    # le colonne filtrabili sono già dichiarate.
    def initialize(project:, range: nil, environment: nil, filters: {})
      @project = project
      @range = range
      @environment = environment.presence
      @filters = filters
    end

    def call
      query = Query.new(
        project_id: @project.id, range: @range, environment: @environment, filters: @filters
      )
      Snapshot.call(query: query, project: @project)
    end
  end
end
