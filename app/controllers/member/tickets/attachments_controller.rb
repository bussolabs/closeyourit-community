# frozen_string_literal: true

module Member
  module Tickets
    # Allegati a livello ticket (screenshot/log del bug): aggiunti e rimossi dalla pagina show
    # SOLO da admin/owner. I membri allegano file via commento. Ticket scoped (visibilità Fase E).
    class AttachmentsController < Member::BaseController
      before_action :set_ticket
      before_action :require_attachments

      def create
        result = Ticketing::AttachToTicket.call(
          ticket: @ticket, files: params[:files],
          actor: Current.account, true_actor: Current.true_account
        )
        if result.ok?
          redirect_to member_ticket_path(@ticket), notice: t("member.tickets.attachments.added")
        else
          redirect_to member_ticket_path(@ticket), alert: result.error.message
        end
      end

      def destroy
        Ticketing::RemoveAttachment.call(
          ticket: @ticket, attachment_id: params[:id],
          actor: Current.account, true_actor: Current.true_account
        )
        redirect_to member_ticket_path(@ticket), notice: t("member.tickets.attachments.removed")
      end

      private

      def set_ticket
        @ticket = visible.tickets.find(params[:ticket_id])
      end

      def require_attachments
        require_permission!("tickets.attachments.manage", scope: @ticket.project)
      end
    end
  end
end
