# frozen_string_literal: true

module Ticketing
  # Assegna/rimuove la milestone di un ticket (dal modulo del ticket e dalla CLI).
  # La milestone deve appartenere all'org (anti-BOLA); blank → rimuove. Result pattern.
  class ChangeMilestone < ApplicationService
    def initialize(organization:, ticket:, milestone_id:, actor: nil, true_actor: nil)
      @organization = organization
      @ticket = ticket
      @milestone_id = milestone_id
      @actor = actor
      @true_actor = true_actor
    end

    def call
      milestone = resolve_milestone
      if milestone == :invalid
        return Result.err(AppError.new(I18n.t("member.tickets.errors.invalid_milestone"), code: "R422-TICKET-004"))
      end
      # No-op: stessa milestone (o entrambe nil) → nessuna mutazione, nessun evento.
      return Result.ok(@ticket) if milestone&.id == @ticket.milestone_id

      from_label = @ticket.milestone&.label
      event = nil
      ApplicationRecord.transaction do
        @ticket.update!(milestone: milestone)
        event = RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                                    action: "milestone_changed",
                                    data: { milestone: { from: from_label, to: milestone&.label } })
      end
      # Notifiche ai watcher DOPO il commit vero (vedi Ticketing::NotifyJob). Chiamato dentro la
      # transazione di Ticketing::UpdateTicket (CYRA-788) l'evento può ancora sparire con un rollback:
      # il job parte solo a commit avvenuto. Senza transazione aperta esegue subito.
      ActiveRecord.after_all_transactions_commit do
        Ticketing::NotifyJob.perform_later(event_id: event.id)
      end
      Result.ok(@ticket)
    end

    private

    # blank → nil (rimuove la milestone); presente ma non del PROGETTO del ticket → :invalid.
    def resolve_milestone
      return nil if @milestone_id.blank?

      @ticket.project.milestones.find_by(id: @milestone_id) || :invalid
    end
  end
end
