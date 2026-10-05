# frozen_string_literal: true

module Api
  module V1
    # Ingest a token bearer (CI / segnali custom): stesso pipeline Normalize+job degli SDK Sentry,
    # ma autenticazione bearer (Api::V1::BaseController). Il :project_id del path deve combaciare col
    # progetto del token (anti-BOLA). Body JSON (parsato da Rails); envelope API standard { data: { id } }.
    class EventsController < Api::V1::IngestBaseController
      # Cap byte in TESTA alla catena (CYRA-112): l'autenticazione ingest, senza bearer né X-Sentry-Auth,
      # legge params[:sentry_key] e con ciò forza il parse del body. Un prepend precede auth e parse, così
      # un evento enorme — anche anonimo o malformato — riceve 413 senza consumare risorse, invece di
      # essere parsato per finire poi in 401/422.
      prepend_before_action :enforce_byte_cap!

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

      def enforce_byte_cap!
        return if request.content_length.to_i <= Errors::Constants::EVENTS_MAX_BYTES

        render_error("R413-INGEST-002", "Evento troppo grande", status: :content_too_large)
      end
    end
  end
end
