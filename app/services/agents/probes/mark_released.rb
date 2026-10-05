# frozen_string_literal: true

module Agents
  module Probes
    # CYRA-624 — «segna come rilasciato»: quando sai tu che è a posto e la macchina non riesce a
    # vederlo.
    #
    # Non è una scorciatoia al controllo: è l'uscita per i casi in cui il controllo non può
    # rispondere — un rilascio fatto a mano, un progetto che non espone come si prova, un guasto del
    # servizio che dura. Chi l'ha premuto e quando resta scritto sulla prova, così fra un mese si
    # legge che «Fatto» quella volta l'ha detto una persona e non un fatto osservato.
    #
    # Chiude anche la prova ancora agganciata: lasciarla viva vorrebbe dire che il controllo
    # successivo può bloccare o far scadere una lavorazione che una persona ha già chiuso.
    class MarkReleased < ApplicationService
      include Agents::Workflows::CtoGate

      def initialize(workflow:, actor:, now: Time.current)
        @workflow = workflow
        @actor = actor
        @now = now
      end

      def call
        return forbidden unless authorized_cto?

        ApplicationRecord.transaction do
          @workflow.lock!
          # Premuto due volte non fa un secondo passaggio a «Fatto» né un secondo evento: chi e
          # quando restano quelli del primo clic.
          return Result.ok(@workflow) if @workflow.completed_at?

          state = @workflow.organization.ticket_statuses.active.category_done.ordered.first
          return missing_status if state.nil?

          @workflow.probes.live.each do |probe|
            probe.update!(closed_at: @now, next_check_at: nil,
                          evidence: probe.evidence.merge("closed_by" => "human",
                                                         "account_id" => @actor&.id, "at" => @now))
          end
          @workflow.update!(completed_at: @now)
          outcome = Ticketing::ChangeStatus.call(organization: @workflow.organization, ticket: @workflow.ticket,
                                               status_id: state.id, channel: :workflow, actor: @actor)
          return outcome if outcome.err?
        end
        Result.ok(@workflow)
      end

      private

      def missing_status
        Result.err(AppError.new(I18n.t("member.tickets.errors.no_target_status"), code: "R422-TICKET-008"))
      end
    end
  end
end
