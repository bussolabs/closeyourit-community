# frozen_string_literal: true

module Uptime
  module Incidents
    # Elimina definitivamente un incident (primary top-level). Cascade completo: le finestre di downtime
    # unificate figlie spariscono con lui (i children hanno `dependent: :nullify` per l'ungroup, quindi
    # qui vanno cancellate ESPLICITAMENTE prima del primary), gli step timeline cadono via
    # `dependent: :destroy`. In transazione: o sparisce tutto o niente. Poi broadcast della lista.
    class Delete < ApplicationService
      def initialize(incident:, actor: nil)
        @incident = incident
        @actor = actor
      end

      def call
        monitor = @incident.monitor
        Uptime::Incident.transaction do
          @incident.children.destroy_all
          @incident.destroy!
        end
        Broadcast.incidents(monitor)
        Result.ok(@incident)
      end
    end
  end
end
