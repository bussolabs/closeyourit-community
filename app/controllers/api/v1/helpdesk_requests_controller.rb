# frozen_string_literal: true

module Api
  module V1
    # The door a visitor's help desk request comes in through (CYRA-940). Same credentials and site
    # allowlist as the other ingest channels; the limits are lower because people write these.
    class HelpdeskRequestsController < Api::V1::IngestBaseController
      rescue_from ActionDispatch::Http::Parameters::ParseError do
        render_error("R422-HELPDESK-001", "Help desk request malformed", status: :unprocessable_content)
      end

      def create
        unless Current.project.helpdesk_enabled?
          return render_error("R403-HELPDESK-001", "This project does not accept help desk requests", status: :forbidden)
        end
        # A bot gets the same answer as a person and nothing is stored: no hint to adapt to.
        return render_accepted if bot?

        result = Helpdesk::ReceiveRequest.call(
          project: Current.project, message: body["message"], email: body["email"],
          page_url: body["page_url"], session_id: body["session_id"], user_agent: request.user_agent
        )
        return render_accepted if result.ok?

        error = result.error
        render_error(error.code, error.message, status: error.status, details: error.details)
      end

      private

      def body = request.request_parameters

      def bot?
        body[Helpdesk::Constants::HONEYPOT_FIELD].present? || Analytics::Device.parse(request.user_agent).bot
      end

      def render_accepted = render(json: { data: { accepted: 1 } }, status: :accepted)

      def render_project_scope_mismatch
        render_error("R404-HELPDESK-001", "Project not found", status: :not_found)
      end
    end
  end
end
