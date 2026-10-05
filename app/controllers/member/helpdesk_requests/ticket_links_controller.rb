# frozen_string_literal: true

module Member
  module HelpdeskRequests
    # POST joins a request to a ticket that exists, DELETE undoes it (CYRA-941).
    class TicketLinksController < Member::BaseController
      include Member::HelpdeskAccess

      before_action :set_helpdesk_request

      def create
        ticket = visible.tickets.find_by(id: params[:ticket_id])
        result = ::Helpdesk::LinkToTicket.call(request: @request_record, ticket: ticket)
        if result.ok?
          redirect_to back_path, notice: t("member.helpdesk.linked")
        else
          redirect_to back_path, alert: result.error.message
        end
      end

      def destroy
        ::Helpdesk::UnlinkTicket.call(request: @request_record)
        redirect_to member_helpdesk_request_path(@request_record), notice: t("member.helpdesk.unlinked")
      end

      private

      # Linking a similar request from another request's page comes back to that page.
      def back_path
        origin = visible.helpdesk_requests.find_by(id: params[:back_to]) if params[:back_to].present?
        member_helpdesk_request_path(origin || @request_record)
      end
    end
  end
end
