# frozen_string_literal: true

module Member
  module Tickets
    # Dipendenze (prerequisiti) tra ticket dalla ticket-show (CYRA-82): il ticket A DIPENDE dal
    # blocker B. Clone di Member::Tickets::LinksController con in più la create. Il gate tickets.edit
    # è un 403 REALE (nascondere il form non basta): senza il permesso la richiesta è respinta
    # server-side, non solo assente dalla UI. La logica (confine tenant, snapshot, evento, ciclo) vive
    # nei service Ticketing::AddDependency/RemoveDependency.
    class DependenciesController < Member::BaseController
      before_action :set_ticket
      before_action -> { require_permission!("tickets.edit", scope: @ticket.project) }

      def create
        result = Ticketing::AddDependency.call(
          ticket: @ticket, blocker_id: params[:blocker_id],
          visible_tickets: visible.tickets,
          actor: Current.account, true_actor: Current.true_account
        )
        if result.ok?
          redirect_to member_ticket_path(@ticket), notice: t("member.tickets.dependencies.added")
        else
          redirect_to member_ticket_path(@ticket), alert: result.error.message
        end
      end

      def destroy
        result = Ticketing::RemoveDependency.call(
          ticket: @ticket, dependency_id: params[:id],
          actor: Current.account, true_actor: Current.true_account
        )
        if result.ok?
          redirect_to member_ticket_path(@ticket), notice: t("member.tickets.dependencies.removed")
        else
          # CYRA-596 — il messaggio è quello del servizio, come nella create. Prima era fisso su
          # «prerequisito non trovato»: qualunque rifiuto diventava quello, compreso «questo lo
          # decide una persona», che è l'unico che dice davvero cosa fare.
          redirect_to member_ticket_path(@ticket), alert: result.error.message
        end
      end

      private

      # Anti-BOLA: il ticket A va risolto tra quelli visibili all'account (come LinksController).
      def set_ticket
        @ticket = visible.tickets.find(params[:ticket_id])
      end
    end
  end
end
