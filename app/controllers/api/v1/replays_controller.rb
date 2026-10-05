# frozen_string_literal: true

module Api
  module V1
    # Ingest dei chunk di session replay (rrweb) a token bearer. Accetta un chunk singolo o un array:
    # un solo Replays::IngestJob per richiesta. Il :project_id del path deve combaciare col progetto
    # del token (anti-BOLA, guard centralizzato in TokenAuthentication). Envelope { data: { accepted } };
    # batch oversize → R413. I byte del replay NON toccano il path caldo: vengono compressi e messi su
    # ActiveStorage nel job. Gli eventi rrweb sono opachi (masking PII già applicato dal client).
    class ReplaysController < Api::V1::IngestBaseController
      rescue_from ActionDispatch::Http::Parameters::ParseError do
        render_error("R422-REPLAY-001", "Chunk di replay malformato", status: :unprocessable_content)
      end

      def create
        # Toggle opt-in OFF → non si registra: 202 accepted:0 senza enqueue. Registrare la navigazione
        # è PII, si attiva esplicitamente per progetto (come analytics_enabled?).
        unless Current.project.session_replay_enabled?
          return render(json: { data: { accepted: 0 } }, status: :accepted)
        end

        list = chunks
        if list.size > Replays::Constants::MAX_BATCH
          return render_error("R413-REPLAY-002", "Batch di chunk troppo grande", status: :content_too_large)
        end

        accepted = list.count { |chunk| valid_chunk?(chunk) }
        if list.any? && accepted.zero?
          return render_error("R422-REPLAY-004", "Nessun chunk valido nel batch", status: :unprocessable_content)
        end

        Replays::IngestJob.perform_later(project_id: Current.project.id, payload: list)
        render json: { data: { accepted: } }, status: :accepted
      end

      private

      # Override del guard anti-BOLA centralizzato (TokenAuthentication): codice di dominio.
      def render_project_scope_mismatch
        render_error("R404-REPLAY-001", "Progetto non trovato", status: :not_found)
      end

      # Body = singolo chunk o array (Rails wrappa un array top-level in params["_json"]).
      def chunks
        body = request.request_parameters
        Array.wrap(body["_json"] || body)
      end

      # Un chunk valido ha l'id di sessione e almeno un evento rrweb.
      def valid_chunk?(chunk)
        chunk.is_a?(Hash) && chunk["replay_session_id"].to_s.present? &&
          chunk["events"].is_a?(Array) && chunk["events"].any?
      end
    end
  end
end
