# frozen_string_literal: true

module Member
  module HelpdeskRequests
    # Erases the visitor's address from a request, for good (CYRA-940).
    class EmailsController < Member::BaseController
      include Member::HelpdeskAccess

      before_action :set_helpdesk_request

      def destroy
        ::Helpdesk::EraseEmail.call(request: @request_record)
        redirect_to member_helpdesk_request_path(@request_record), notice: t("member.helpdesk.email_erased")
      end
    end
  end
end
