# frozen_string_literal: true

module Errors
  # CYRA-45: triage di più gruppi d'errore in un colpo (dopo un deploy rumoroso: 30 gruppi da feature
  # flag rotta → resolve/ignore in massa dalla lista). Specializza Observability::BulkTriage riusando
  # Errors::Triage; precarica il progetto e la release live per evitare l'N+1 dell'audit di regressione.
  class BulkTriage < Observability::BulkTriage
    private

    def triage_class = Errors::Triage
    def invalid_action_code = "R422-ERROR-002"
    def group_includes = [ :project ]

    def triage_options(group, releases)
      { resolved_release: releases.fetch(group.project_id, :auto) }
    end

    # Precalcola la release "live" (audit di regressione CYRA-44) UNA volta per progetto DISTINTO: senza,
    # Errors::Triage#regression_audit interrogherebbe projects_releases per OGNI gruppo → N+1 quando il bulk
    # resolve tocca N gruppi dello stesso progetto (lo scenario del ticket). Solo per resolve; ignore/reopen
    # non toccano l'audit (:auto è innocuo — quel ramo non fa query).
    def triage_context(groups)
      return {} unless @action == "resolve"

      groups.map(&:project).uniq.index_by(&:id)
            .transform_values { |project| Projects::Release.live_version(project) }
    end
  end
end
