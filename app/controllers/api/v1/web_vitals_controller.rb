# frozen_string_literal: true

module Api
  module V1
    # Ingest delle misure di velocità prese dai visitatori veri (CYRA-538). Accetta una misura sola o
    # un array; una richiesta, un job.
    #
    # Endpoint SUO e non un ramo di quello dei pageview: sono due forme diverse, e mescolarle
    # renderebbe il normalizzatore dei pageview responsabile di due contratti. In questo codebase
    # ogni segnale ha il suo endpoint, il suo tetto di batch, il suo throttle e la sua retention —
    # metrics, logs, pageview, replay: questo è il sesto.
    #
    # BOUNDARY PII identico ai pageview: IP e user-agent muoiono QUI dentro Analytics::Anonymize; al
    # job arrivano solo il tipo di dispositivo, il browser, il sistema e il paese.
    class WebVitalsController < Api::V1::IngestBaseController
      rescue_from ActionDispatch::Http::Parameters::ParseError do
        render_error("R422-WEBVITAL-001", "Misura malformata", status: :unprocessable_content)
      end

      def create
        # Stessa porta dei pageview: chi non raccoglie le statistiche non raccoglie nemmeno queste.
        # 202 con zero accettate, come per i bot: un client che continua a mandare non va punito, e
        # non è un suo errore.
        return render(json: { data: { accepted: 0 } }, status: :accepted) unless Current.project.analytics_enabled?

        list = measurements
        if list.size > Analytics::Constants::WEB_VITALS_MAX_BATCH
          return render_error("R413-WEBVITAL-002", "Batch di misure troppo grande", status: :content_too_large)
        end

        accepted = list.count { |item| Analytics::WebVitals::Record.acceptable?(item) }
        if list.any? && accepted.zero?
          return render_error("R422-WEBVITAL-004", "Nessuna misura valida nel batch", status: :unprocessable_content)
        end

        identity = Analytics::Anonymize.call(
          ip: request.remote_ip, user_agent: request.user_agent, project_id: Current.project.id
        ).value
        return render(json: { data: { accepted: 0 } }, status: :accepted) if identity.bot

        Analytics::WebVitalsIngestJob.perform_later(
          project_id: Current.project.id,
          context: {
            device_type: identity.device_type, browser: identity.browser, os: identity.os,
            country_code: Analytics::Geo.country_code(request.remote_ip)
          },
          payload: list
        )
        render json: { data: { accepted: } }, status: :accepted
      end

      private

      def render_project_scope_mismatch
        render_error("R404-WEBVITAL-001", "Progetto non trovato", status: :not_found)
      end

      def measurements
        body = request.request_parameters
        Array.wrap(body["_json"] || body)
      end
    end
  end
end
