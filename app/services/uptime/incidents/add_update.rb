# frozen_string_literal: true

module Uptime
  module Incidents
    # Appende uno step alla timeline di un incident già narrato e denormalizza la phase corrente,
    # in transazione. Usato per gli step successivi al primo (es. Investigazione → Monitoraggio →
    # Rientrato). Il primo step si crea con GroupAndUpdate.
    class AddUpdate < ApplicationService
      def initialize(incident:, phase:, body: nil, actor: nil)
        @incident = incident
        @phase = phase.to_s
        @body = body
        @actor = actor
      end

      def call
        unless Uptime::IncidentUpdate.phases.key?(@phase)
          return Result.err(AppError.new("Step non valido.",
                                         code: "R422-UPTIME-002", status: :unprocessable_content))
        end

        update = nil
        ApplicationRecord.transaction do
          update = @incident.updates.create!(phase: @phase, body: @body, created_by: @actor)
          @incident.update!(phase: @phase)
        end
        Broadcast.incidents(@incident.monitor)
        Result.ok(update)
      end
    end
  end
end
