# frozen_string_literal: true

module Metrics
  # CYRA-45: triage di più gruppi-metrica in un colpo (query/metodi lenti di rumore da un deploy →
  # resolve/ignore in massa dalla lista). Specializza Observability::BulkTriage riusando Metrics::Triage.
  class BulkTriage < Observability::BulkTriage
    private

    def triage_class = Metrics::Triage
    def invalid_action_code = "R422-METRIC-005"
    # CYRA-822 — il canale Member dichiara i progetti toccati nel broadcast di fine bulk: senza il
    # preload sarebbe una lettura del progetto per ogni gruppo triato.
    def group_includes = [ :project ]
  end
end
