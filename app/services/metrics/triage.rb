# frozen_string_literal: true

module Metrics
  # CYRA-45: smistamento di un gruppo-metrica (resolve/ignore/reopen). Specializza Observability::Triage
  # senza audit release-aware (specifico degli errori): una query lenta non regredisce per release.
  # Condiviso da UI Member e canale CLI.
  class Triage < Observability::Triage
    private

    def invalid_action_code = "R422-METRIC-005"
  end
end
