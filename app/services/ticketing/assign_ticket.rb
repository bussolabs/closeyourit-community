# frozen_string_literal: true

module Ticketing
  # Assegna (o disassegna, id vuoto) un ticket. L'assignee deve essere membro dell'org
  # (anti-BOLA: un id fuori org non viene trovato → resta non assegnato). Result pattern.
  class AssignTicket < ApplicationService
    def initialize(organization:, ticket:, assignee_id:, actor: nil, true_actor: nil)
      @organization = organization
      @ticket = ticket
      @assignee_id = assignee_id
      @actor = actor
      @true_actor = true_actor
    end

    def call
      # assignee = membro dell'org (anti-BOLA: id fuori org → nil); blank → disassegna.
      assignee = @assignee_id.blank? ? nil : @organization.accounts.find_by(id: @assignee_id)
      # No-op: stesso assignee (incluso nil==nil = già non assegnato) → nessun evento.
      return Result.ok(@ticket) if assignee&.id == @ticket.assignee_id

      from_name = @ticket.assignee&.name
      event = nil
      ApplicationRecord.transaction do
        @ticket.update!(assignee: assignee)
        event =
          if assignee
            RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                                action: "assigned",
                                data: { assignee: { from: from_name, to: assignee.name } })
          else
            RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                                action: "unassigned",
                                data: { assignee: { from: from_name, to: nil } })
          end
      end
      # Realtime + notifiche DOPO il commit — quello vero, non solo quello della transazione qui sopra.
      # Chiamato dentro la transazione di Ticketing::UpdateTicket (CYRA-788) un rifiuto del traguardo
      # annulla anche l'assegnazione: il job e il broadcast non devono partire su un evento che non
      # esiste più. Senza transazione aperta `after_all_transactions_commit` esegue subito. L'evento
      # assigned/unassigned va in timeline via RecordActivity; qui aggiorniamo il display assignee
      # nella sidebar della show.
      ActiveRecord.after_all_transactions_commit do
        broadcast_assignee
        Ticketing::NotifyJob.perform_later(event_id: event.id)
      end
      Result.ok(@ticket)
    end

    private

    # Replace realtime del display assignee (sidebar show). Viewer-agnostico: il partial rende il
    # read-only; il dropdown di gestione resta per-viewer (chi gestisce lo riottiene col redirect).
    def broadcast_assignee
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.ticket(@ticket),
        target: "#{ActionView::RecordIdentifier.dom_id(@ticket)}_assignee",
        partial: "member/tickets/assignee",
        locals: { ticket: @ticket }
      )
    end
  end
end
