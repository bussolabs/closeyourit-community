# frozen_string_literal: true

module Vulnerabilities
  # Giro giornaliero (CYRA-1144): riapre le vulnerabilità ignorate arrivate alla scadenza e avvisa.
  # Una query e qualche accodamento: resta sulla corsia `maintenance` dei controlli, come il fan-out
  # delle scansioni.
  class ReopenExpiredIgnoresJob < ApplicationJob
    queue_as :maintenance

    def perform
      Vulnerabilities::ReopenExpiredIgnores.call
    end
  end
end
