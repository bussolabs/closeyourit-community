# frozen_string_literal: true

module Api
  module V1
    # Ingest a token bearer (CI / segnali custom): stesso pipeline Normalize+job degli SDK Sentry,
    # ma autenticazione bearer (Api::V1::BaseController). Il :project_id del path deve combaciare col
    # progetto del token (anti-BOLA). Body JSON (parsato da Rails); envelope API standard { data: { id } }.
    class EventsController < Api::V1::IngestBaseController
      rescue_from ActionDispatch::Http::Parameters::ParseError do
        render_error("R422-INGEST-001", "Evento malformato", status: :unprocessable_content)
      end

      def create
        payload = request.request_parameters
        unless Errors::Ingest::EventPayload.valid?(payload)
          return render_error("R422-INGEST-001", "Malformed event", status: :unprocessable_content)
        end
        Errors::Ingest::Enqueue.call(project: Current.project, payload: payload)
        render json: { data: { id: payload["event_id"] } }, status: :accepted
      end

      private

      # Own limit and code for the byte cap of IngestBaseController (CYRA-112).
      def byte_cap
        Errors::Constants::EVENTS_MAX_BYTES
      end

      def byte_cap_error_code
        "R413-INGEST-002"
      end
    end
  end
end
