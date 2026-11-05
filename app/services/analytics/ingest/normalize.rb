# frozen_string_literal: true

module Analytics
  module Ingest
    # Normalizza un pageview raw nel sottoinsieme persistito. Lavora SOLO sul payload (nessuna PII:
    # IP/UA sono già stati consumati da Analytics::Anonymize nel controller). NON tocca il DB.
    # Regole: hostname downcase; path = solo pathname con leading slash (la query non deve MAI
    # arrivare — difensivamente viene troncata); referrer ridotto al solo hostname e scartato se
    # uguale all'hostname della pagina (navigazione interna = traffico diretto, semantica Plausible);
    # UTM troncati; occurred_at clampato sul futuro (clock-skew client).
    class Normalize < ApplicationService
      include ::Ingest::PayloadCleaning
      include ::Ingest::EpochTime

      Normalized = Data.define(
        :event_id, :name, :hostname, :path, :referrer_host,
        :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content,
        :screen_class, :environment, :occurred_at
      )

      UTM_MAX_LENGTH = 150
      NAME_MAX_LENGTH = 120
      DEFAULT_ENVIRONMENT = "production"
      # Nome dell'evento "visita pagina"; un name diverso è un custom event (goal/conversione).
      PAGEVIEW_NAME = "pageview"

      # Categorie di viewport (px, larghezza) inviate dal client — dimensione "screen size" della
      # dashboard, distinta dal device_type derivato dall'UA. Breakpoint stile Plausible.
      SCREEN_BREAKPOINTS = [ [ 576, "mobile" ], [ 992, "tablet" ], [ 1440, "laptop" ] ].freeze

      def initialize(payload:)
        # Strip ricorsivo dei null byte: Postgres li rifiuta in text/jsonb e UN pageview avvelenato
        # farebbe fallire l'insert_all dell'INTERO batch (fino a 100 pageview sani persi). Pattern
        # gemello di Logs/Errors/Metrics::Ingest::Normalize (CYRA-169).
        @payload = deep_clean(payload.is_a?(Hash) ? payload : {})
      end

      def call
        host = hostname
        Normalized.new(
          event_id: @payload["event_id"].to_s.presence || SecureRandom.uuid,
          name: event_name,
          hostname: host,
          path: path,
          referrer_host: referrer_host(host),
          utm_source: utm("utm_source"),
          utm_medium: utm("utm_medium"),
          utm_campaign: utm("utm_campaign"),
          utm_term: utm("utm_term"),
          utm_content: utm("utm_content"),
          screen_class: screen_class,
          environment: @payload["environment"].to_s.presence || DEFAULT_ENVIRONMENT,
          occurred_at: parse_time(@payload["occurred_at"])
        )
      end

      private

      def hostname
        @payload["hostname"].to_s.strip.downcase
      end

      # Solo pathname: la query/fragment non devono viaggiare (contratto SDK), ma un client custom
      # potrebbe mandarli — qui si troncano. Path non vuoto → leading slash garantito.
      def path
        raw = @payload["path"].to_s.strip.split(/[?#]/, 2).first.to_s
        return "" if raw.blank?

        raw.start_with?("/") ? raw : "/#{raw}"
      end

      # document.referrer è un URL assoluto: si estrae il solo hostname. Referrer same-host =
      # navigazione interna → nil (traffico diretto). Valore non parsabile o senza host → nil.
      def referrer_host(page_host)
        raw = @payload["referrer"].to_s.strip
        return nil if raw.blank?

        host = begin
          URI.parse(raw).host
        rescue URI::InvalidURIError
          nil
        end
        host = host.to_s.downcase.presence
        return nil if host.nil? || host == page_host

        host
      end

      def utm(key)
        @payload[key].to_s.strip.presence&.slice(0, UTM_MAX_LENGTH)
      end

      # Nome evento: default "pageview" se assente/blank; troncato per sicurezza.
      def event_name
        @payload["name"].to_s.strip.presence&.slice(0, NAME_MAX_LENGTH) || PAGEVIEW_NAME
      end

      # screen_width (px) del client → categoria di viewport; nil se assente o non un intero positivo.
      def screen_class
        raw = @payload["screen_width"]
        width = raw.is_a?(Numeric) ? raw.to_i : raw.to_s[/\A\d+/].to_i
        return nil if width <= 0

        SCREEN_BREAKPOINTS.each { |limit, label| return label if width < limit }
        "desktop"
      end
    end
  end
end
