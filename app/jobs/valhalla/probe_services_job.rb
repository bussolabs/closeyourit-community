# frozen_string_literal: true

module Valhalla
  # Ricorrente (recurring.yml, ogni 5 minuti): sonda i servizi esterni collegati e scrive lo snapshot
  # in Solid Cache che /valhalla/health legge (mai probe sincrone nella request, vedi ProbeServices).
  class ProbeServicesJob < ApplicationJob
    queue_as :maintenance

    def perform
      Valhalla::ProbeServices.call
    end
  end
end
