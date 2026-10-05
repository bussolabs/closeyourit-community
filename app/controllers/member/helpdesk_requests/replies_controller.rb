# frozen_string_literal: true

module Member
  module HelpdeskRequests
    # POST answers the visitor by email (CYRA-943).
    class RepliesController < Member::BaseController
      include Member::HelpdeskAccess

      before_action :set_helpdesk_request

      def create
        result = ::Helpdesk::Reply.call(request: @request_record, author: Current.account, body: params[:body])
        if result.ok?
          redirect_to member_helpdesk_request_path(@request_record), notice: t("member.helpdesk.replied")
        else
          redirect_to member_helpdesk_request_path(@request_record), alert: result.error.message
        end
      end
    end
  end
end
