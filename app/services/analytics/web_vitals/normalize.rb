# frozen_string_literal: true

module Analytics
  module WebVitals
    # Normalizza una misura di velocità grezza (CYRA-538). Lavora SOLO sul payload: IP e user-agent
    # sono già stati consumati dal controller, come per i pageview.
    #
    # L'ESITO SI RICALCOLA QUI. Il client ne manda uno, ma fidarsene vorrebbe dire lasciare che sia
    # il misurato a darsi il voto — e basterebbe un client vecchio, con soglie superate, per vedere
    # verde dove Google vede rosso.
    class Normalize < ApplicationService
      include ::Ingest::PayloadCleaning
      include ::Ingest::EpochTime

      Normalized = Data.define(:event_id, :metric, :value, :rating, :hostname, :path,
                               :environment, :navigation_type, :occurred_at)

      DEFAULT_ENVIRONMENT = "production"

      # Tetti di sanità. Un valore folle avvelena un percentile molto più di quanto avveleni una
      # media: basta una manciata di misure assurde per spostare il p75 di un sito intero.
      MAX_MS = 60_000
      MAX_CLS = 10
      NAVIGATION_TYPES = %w[navigate reload back-forward prerender restore].freeze

      def initialize(payload:)
        @payload = deep_clean(payload.is_a?(Hash) ? payload : {})
      end

      def call
        metric = @payload["metric"].to_s.strip.downcase
        value = value_for(metric)

        Normalized.new(
          event_id: @payload["event_id"].to_s.presence || SecureRandom.uuid,
          metric: metric,
          value: value,
          rating: Seo::Vitals.rating(metric, value)&.to_s&.tr("_", "-"),
          hostname: @payload["hostname"].to_s.strip.downcase,
          path: path,
          environment: @payload["environment"].to_s.presence || DEFAULT_ENVIRONMENT,
          navigation_type: navigation_type,
          occurred_at: parse_time(@payload["occurred_at"])
        )
      end

      private

      # Fuori tetto → nil, cioè misura scartata: meglio una misura in meno che un percentile falsato.
      def value_for(metric)
        raw = @payload["value"]
        return nil unless raw.is_a?(Numeric) || raw.to_s.match?(/\A-?\d+(\.\d+)?\z/)

        value = raw.to_f
        return nil if value.negative?
        return nil if value > (Seo::Vitals.unitless?(metric) ? MAX_CLS : MAX_MS)

        value
      end

      # Solo il pathname: la query non deve viaggiare (contratto SDK), ma un client scritto in casa
      # potrebbe mandarla — qui si tronca. Stessa regola dei pageview.
      def path
        raw = @payload["path"].to_s.strip.split(/[?#]/, 2).first.to_s
        return "" if raw.blank?

        raw.start_with?("/") ? raw : "/#{raw}"
      end

      # Un ripristino dalla cache del browser non è un caricamento: tenerlo insieme agli altri
      # abbasserebbe i tempi raccontando una velocità che nessuno ha vissuto. Si conserva il tipo,
      # così la lettura può separarli quando servirà.
      def navigation_type
        kind = @payload["navigation_type"].to_s.strip.downcase
        NAVIGATION_TYPES.include?(kind) ? kind : nil
      end
    end
  end
end
