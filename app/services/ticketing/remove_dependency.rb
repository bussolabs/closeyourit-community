# frozen_string_literal: true

module Ticketing
  # Rimuove un prerequisito da un ticket (CYRA-82). Gemello in scrittura di Member::Tickets::
  # LinksController#destroy, ma con Result pattern e RecordActivity: la rimozione è un fatto d'audit.
  #
  # ANTI-BOLA: la dependency si risale SEMPRE attraverso il ticket visibile corrente
  # (@ticket.dependencies), MAI un Connections::TicketDependency.find(params[:id]) globale — un id
  # d'altri sarebbe una BOLA. Assente nello scope del ticket → 404 (idempotenza: una seconda rimozione
  # trova già il vuoto e risponde 404 chiaro, non 500). Mutazione + evento nella STESSA transazione.
  class RemoveDependency < ApplicationService
    include DependencyBroadcasts

    def initialize(ticket:, dependency_id:, actor: nil, true_actor: nil)
      @ticket = ticket
      @dependency_id = dependency_id
      @actor = actor
      @true_actor = true_actor
    end

    def call
      forbidden = actor_forbidden
      return Result.err(forbidden) if forbidden

      dependency = @ticket.dependencies.find_by(id: @dependency_id)
      if dependency.nil?
        return Result.err(AppError.new(I18n.t("member.tickets.dependencies.errors.not_found"),
                                       code: "R404-TICKET-016", status: :not_found))
      end

      # Snapshot del blocker PRIMA della destroy: dopo, `dependency.blocker` sarebbe già staccato e il
      # code/title non più leggibili per l'evento.
      blocker = dependency.blocker
      ApplicationRecord.transaction do
        dependency.destroy!
        RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                            action: "dependency_removed",
                            data: { code: blocker.code, title: blocker.title })
      end
      # Tolto un prerequisito, A può non essere più "bloccato": rinfresca la sua board.
      broadcast_dependency_board(@ticket)
      Result.ok(dependency)
    end

    private

      # CYRA-596 — prima di qualunque altra cosa, e prima di leggere il dato.
      #
      # Il discriminante e' l'ATTORE, non il canale: operatore e host usano lo STESSO canale CLI e lo
      # stesso tipo di token, quindi chiudere il canale chiuderebbe anche la persona.
      #
      # Sta PRIMA della ricerca di proposito. Rispondere «non trovato» a chi non aveva comunque il
      # diritto di chiedere direbbe la cosa sbagliata: farebbe credere che il problema sia il dato, e
      # cambierebbe risposta a seconda di che cosa esiste — cioe' racconterebbe a una macchina quali
      # prerequisiti ci sono sul ticket.
      def actor_forbidden
        return nil if @actor.present? && @actor.human?

        AppError.new(I18n.t("member.tickets.dependencies.errors.human_only"),
                     code: "R403-TICKET-001", status: :forbidden)
      end
  end
end
