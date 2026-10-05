# frozen_string_literal: true

module Api
  module V1
    # Ingest dei log strutturati a token bearer. Accetta un singolo log o un array (alto volume): un
    # solo Logs::IngestJob per richiesta (batch insert_all). Il :project_id del path deve combaciare
    # col progetto del token (anti-BOLA). Envelope { data: { accepted } }; batch oversize → R413.
    class LogsController < Api::V1::IngestBaseController
      rescue_from ActionDispatch::Http::Parameters::ParseError do
        render_error("R422-LOG-001", "Log malformato", status: :unprocessable_content)
      end

      def create
        list = entries
        if list.size > Logs::Constants::MAX_BATCH
          return render_error("R413-LOG-002", "Batch di log troppo grande", status: :content_too_large)
        end

        # Conta gli item davvero accettabili (Hash + message non vuoto): un batch non vuoto in cui
        # TUTTI vengono scartati è un errore del client, non un 202 silenzioso. Batch parziale → 202.
        accepted = list.count { |item| Logs::Ingest::Record.acceptable?(item) }
        if list.any? && accepted.zero?
          return render_error("R422-LOG-004", "Nessun log valido nel batch", status: :unprocessable_content)
        end

        Logs::IngestJob.perform_later(project_id: Current.project.id, payload: list)
        render json: { data: { accepted: } }, status: :accepted
      end

      private

      # Override del guard anti-BOLA centralizzato (TokenAuthentication): i log usano il codice
      # envelope di dominio documentato R404-LOG-001 invece del bare 404 di default.
      def render_project_scope_mismatch
        render_error("R404-LOG-001", "Progetto non trovato", status: :not_found)
      end

      # Body = singolo oggetto JSON o array (Rails wrappa un array top-level in params["_json"]).
      def entries
        body = request.request_parameters
        Array.wrap(body["_json"] || body)
      end
    end
  end
end
