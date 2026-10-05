# frozen_string_literal: true

module Ticketing
  # Imposta (o rimuove, id vuoto) il revisore di un ticket. Il reviewer deve essere membro dell'org
  # (anti-BOLA: un id fuori org non viene trovato → resta invariato/nil). Result pattern.
  #
  # A differenza di AssignTicket, NON emette NotifyJob: il cambio revisore non notifica nessuno. La
  # notifica al reviewer vive SOLO all'ingresso del ticket in uno status review_gate (vedi
  # Notifications::DispatchEvent). Qui registriamo solo l'evento di cronologia + il replace realtime.
  class SetReviewer < ApplicationService
    def initialize(organization:, ticket:, reviewer_id:, actor: nil, true_actor: nil)
      @organization = organization
      @ticket = ticket
      @reviewer_id = reviewer_id
      @actor = actor
      @true_actor = true_actor
    end

    def call
      # reviewer = membro dell'org (anti-BOLA: id fuori org → nil); blank → rimuove il revisore.
      reviewer = @reviewer_id.blank? ? nil : @organization.accounts.find_by(id: @reviewer_id)
      # No-op: stesso reviewer (incluso nil==nil = già senza revisore) → nessun evento.
      return Result.ok(@ticket) if reviewer&.id == @ticket.reviewer_id

      from_name = @ticket.reviewer&.name
      event = nil
      ApplicationRecord.transaction do
        @ticket.update!(reviewer: reviewer)
        event = RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                                    action: "reviewer_changed",
                                    data: { reviewer: { from: from_name, to: reviewer&.name } })
      end
      # Post-commit: aggiorna il display revisore nella sidebar della show (viewer-agnostico).
      broadcast_reviewer
      Result.ok(@ticket)
    end

    private

    # Replace realtime del display revisore. Come per l'assignee: il partial rende il read-only,
    # il dropdown di gestione resta per-viewer (chi gestisce lo riottiene col proprio redirect).
    def broadcast_reviewer
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.ticket(@ticket),
        target: "#{ActionView::RecordIdentifier.dom_id(@ticket)}_reviewer",
        partial: "member/tickets/reviewer",
        locals: { ticket: @ticket }
      )
    end
  end
end
