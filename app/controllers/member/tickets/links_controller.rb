# frozen_string_literal: true

module Member
  module Tickets
    # Rimozione di un collegamento ticket↔ticket (creato dal gate duplicati). La creazione NON
    # passa da qui: nasce solo dal flusso di confronto (Ticketing::ResolveDuplicate).
    class LinksController < Member::BaseController
      before_action :set_ticket
      before_action -> { require_permission!("tickets.edit", scope: @ticket.project) }

      def destroy
        link = Connections::TicketLink.involving(@ticket).find_by(id: params[:id])
        if link.nil?
          redirect_to member_ticket_path(@ticket), alert: t("member.tickets.links.not_found")
        else
          link.destroy
          redirect_to member_ticket_path(@ticket), notice: t("member.tickets.links.removed")
        end
      end

      private

      # Anti-BOLA: il ticket va risolto tra quelli visibili all'account.
      def set_ticket
        @ticket = visible.tickets.find(params[:ticket_id])
      end
    end
  end
end
