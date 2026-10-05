# frozen_string_literal: true

module Member
  module HelpdeskRequests
    # PUT discards a request, DELETE brings it back (CYRA-940). Nothing is deleted: a mistake is undone.
    class DiscardsController < Member::BaseController
      include Member::HelpdeskAccess

      before_action :set_helpdesk_request

      def update
        ::Helpdesk::DiscardRequest.call(request: @request_record, actor: Current.account)
        redirect_to member_helpdesk_requests_path, notice: t("member.helpdesk.discarded")
      end

      def destroy
        ::Helpdesk::RestoreRequest.call(request: @request_record)
        redirect_to member_helpdesk_request_path(@request_record), notice: t("member.helpdesk.restored")
      end
    end
  end
end
