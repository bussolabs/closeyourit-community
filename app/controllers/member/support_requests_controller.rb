# frozen_string_literal: true

module Member
  # The Support button in the footer (CYRA-935): saves the message with the page the person was on
  # and answers inside the support screen's frame, sent or with the error. The index lists one's own.
  class SupportRequestsController < Member::BaseController
    permission_not_required "Support: anyone signed in can ask for help."

    # The requests this person sent from this organization, newest first.
    def index
      @pagination = paginate(Support::Request.where(account: Current.account, organization: current_organization)
                                             .order(created_at: :desc))
      @requests = @pagination.records
    end

    def create
      result = Support::Requests::Create.call(
        account: Current.account, organization: current_organization, body: params[:body],
        client_context: params.fetch(:context, {}).permit(*Support::Constants::CLIENT_CONTEXT_KEYS),
        request_details: { role: current_membership&.role, user_agent: request.user_agent, request_id: request.request_id }
      )
      if result.ok?
        render partial: "member/support_requests/sent"
      else
        render partial: "member/support_requests/form", locals: { body: params[:body], error: result.error.message },
               status: :unprocessable_content
      end
    end
  end
end
