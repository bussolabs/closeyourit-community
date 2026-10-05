# frozen_string_literal: true

module Api
  module V1
    # Ingest pageview (web analytics) a token bearer. Accetta un singolo pageview o un array: un solo
    # Analytics::IngestJob per richiesta (batch insert_all). Il :project_id del path deve combaciare
    # col progetto del token (anti-BOLA). Envelope { data: { accepted } }; batch oversize → R413.
    #
    # BOUNDARY PII: IP (socket) e User-Agent (header) vengono consumati QUI da Analytics::Anonymize
    # — al job passano solo visitor_hash/browser/os anonimi (gli args Solid Queue vivono su Postgres).
    # Richieste da bot → 202 { accepted: 0 } senza enqueue (non è un errore del client).
    class PageviewsController < Api::V1::IngestBaseController
      rescue_from ActionDispatch::Http::Parameters::ParseError do
        render_error("R422-PAGEVIEW-001", "Pageview malformato", status: :unprocessable_content)
      end

      def create
        # Toggle Settings "Raccogli analytics" OFF → non si raccoglie: 202 accepted:0 senza enqueue
        # (come i bot). Lettura di colonna, nessuna query sul path caldo; il token già scoping-a il progetto.
        unless Current.project.analytics_enabled?
          return render(json: { data: { accepted: 0 } }, status: :accepted)
        end

        list = pageviews
        if list.size > Analytics::Constants::MAX_BATCH
          return render_error("R413-PAGEVIEW-002", "Batch di pageview troppo grande", status: :content_too_large)
        end

        accepted = list.count { |item| Analytics::Ingest::Record.acceptable?(item) }
        if list.any? && accepted.zero?
          return render_error("R422-PAGEVIEW-004", "Nessun pageview valido nel batch", status: :unprocessable_content)
        end

        identity = Analytics::Anonymize.call(
          ip: request.remote_ip, user_agent: request.user_agent, project_id: Current.project.id
        ).value
        return render(json: { data: { accepted: 0 } }, status: :accepted) if identity.bot

        # Geo INLINE (boundary PII): l'IP produce solo il country_code e poi muore — al job passa il
        # codice paese anonimo, mai l'IP. Degrado silenzioso a nil se il DB GeoLite2 non è presente.
        country_code = Analytics::Geo.country_code(request.remote_ip)

        Analytics::IngestJob.perform_later(
          project_id: Current.project.id,
          context: {
            visitor_hash: identity.visitor_hash, browser: identity.browser, os: identity.os,
            device_type: identity.device_type, browser_version: identity.browser_version,
            os_version: identity.os_version, country_code: country_code
          },
          payload: list
        )
        render json: { data: { accepted: } }, status: :accepted
      end

      private

      # Override del guard anti-BOLA centralizzato (TokenAuthentication): codice di dominio
      # documentato R404-PAGEVIEW-001 invece del bare 404 di default.
      def render_project_scope_mismatch
        render_error("R404-PAGEVIEW-001", "Progetto non trovato", status: :not_found)
      end

      # Body = singolo oggetto JSON o array (Rails wrappa un array top-level in params["_json"]).
      def pageviews
        body = request.request_parameters
        Array.wrap(body["_json"] || body)
      end
    end
  end
end
