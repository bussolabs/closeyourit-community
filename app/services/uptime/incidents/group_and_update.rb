# frozen_string_literal: true

module Uptime
  module Incidents
    # Unifica gli incident selezionati in un incident logico e vi pubblica il primo step della timeline,
    # in UNA transazione. Il primary è il più vecchio (started_at min); gli altri (e i loro eventuali
    # figli) vengono reparentati sotto di lui (grouping a un livello). Con un solo incident selezionato
    # non c'è raggruppamento: si posta solo l'update. Anti-BOLA: solo incident top-level DEL monitor.
    class GroupAndUpdate < ApplicationService
      def initialize(monitor:, incident_ids:, phase:, body: nil, actor: nil)
        @monitor = monitor
        @incident_ids = Array(incident_ids).map(&:to_s).uniq
        @phase = phase.to_s
        @body = body
        @actor = actor
      end

      def call
        incidents = @monitor.incidents.top_level.where(id: @incident_ids).to_a
        if incidents.empty? || incidents.size != @incident_ids.size
          return Result.err(AppError.new("Seleziona incident validi dello stesso monitor.",
                                         code: "R422-UPTIME-001", status: :unprocessable_content))
        end
        unless Uptime::IncidentUpdate.phases.key?(@phase)
          return Result.err(AppError.new("Step non valido.",
                                         code: "R422-UPTIME-002", status: :unprocessable_content))
        end

        primary = incidents.min_by(&:started_at)
        others = incidents - [ primary ]
        ApplicationRecord.transaction do
          reparent!(primary, others) if others.any?
          primary.updates.create!(phase: @phase, body: @body, created_by: @actor)
          primary.update!(phase: @phase)
        end
        Broadcast.incidents(@monitor)
        Result.ok(primary.reload)
      end

      private

      # Sposta gli altri selezionati E i loro figli già esistenti sotto il primary (flat, un livello).
      def reparent!(primary, others)
        other_ids = others.map(&:id)
        descendant_ids = Uptime::Incident.where(parent_id: other_ids).pluck(:id)
        Uptime::Incident.where(id: other_ids + descendant_ids).update_all(parent_id: primary.id)
      end
    end
  end
end
