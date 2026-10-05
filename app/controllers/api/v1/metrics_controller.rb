# frozen_string_literal: true

module Api
  module V1
    # Ingest delle metriche di performance (query/metodi lenti) a token bearer. Accetta un singolo
    # campione o un array (volume alto). Il :project_id del path deve combaciare col progetto del
    # token (anti-BOLA). Persistenza async via Metrics::IngestJob. Envelope { data: { accepted } }.
    class MetricsController < Api::V1::IngestBaseController
      # Cap byte in TESTA alla catena (CYRA-112): l'autenticazione ingest, senza bearer né X-Sentry-Auth,
      # legge params[:sentry_key] e con ciò forza il parse del body. Un prepend precede auth e parse, così
      # un batch enorme — anche anonimo o malformato — riceve 413 senza consumare risorse. Il cap sul
      # NUMERO di campioni (R413-METRIC-004) resta in #create: contare gli item richiede comunque il parse.
      prepend_before_action :enforce_byte_cap!

      rescue_from ActionDispatch::Http::Parameters::ParseError do
        render_error("R422-METRIC-001", "Metrica malformata", status: :unprocessable_content)
      end

      def create
        list = samples
        if list.size > Metrics::Constants::MAX_BATCH
          return render_error("R413-METRIC-004", "Batch di metriche troppo grande", status: :content_too_large)
        end

        # UN solo job per richiesta (CYRA-43): il batch raggruppa per fingerprint e applica gli
        # aggregati con un update per gruppo, invece di N job/N transazioni per N campioni.
        Metrics::IngestJob.perform_later(project_id: Current.project.id, payload: list)
        render json: { data: { accepted: list.size } }, status: :accepted
      end

      private

      def enforce_byte_cap!
        return if request.content_length.to_i <= Metrics::Constants::MAX_BYTES

        render_error("R413-METRIC-006", "Payload delle metriche troppo grande", status: :content_too_large)
      end

      # Body = singolo oggetto JSON o array (Rails wrappa un array top-level in params["_json"]).
      def samples
        body = request.request_parameters
        Array.wrap(body["_json"] || body)
      end
    end
  end
end
