# frozen_string_literal: true

module Analytics
  # Pageview immutabile (solo created_at), sesto dominio di telemetria — flat come Logs:: (niente
  # group/fingerprint). project_id denormalizzato per retention/scoping senza join. Idempotente su
  # event_id per progetto (retry/at-least-once dell'SDK). Il visitor_hash è anonimo by-design:
  # SHA-256 di [salt giornaliero, ip, user_agent, project_id] calcolato nel controller — IP e UA
  # raw non arrivano mai qui (vedi Analytics::Anonymize).
  class Pageview < ApplicationRecord
    # CYRA-750 — la tabella è divisa a fette mensili su `created_at`: da qui la chiave primaria
    # riportata a `id` e il gemello per la scrittura in blocco.
    include PartitionedTable

    belongs_to :project, class_name: "Projects::Project", inverse_of: :analytics_pageviews

    validates :event_id, presence: true, uniqueness: { scope: :project_id }
    validates :visitor_hash, presence: true
    validates :hostname, presence: true
    validates :path, presence: true
    validates :occurred_at, presence: true

    scope :recent, -> { order(occurred_at: :desc, id: :desc) }

    # Nome dell'evento "visita pagina": le metriche di traffico contano solo questi, i custom event
    # (name diverso) contribuiscono alle conversioni dei goal, non al traffico.
    PAGEVIEW_NAME = "pageview"

    # --- Primitivi di query (le aggregazioni vivono in Analytics::Query, che li compone) ----------

    # Range dashboard: niente 30m (il breve termine lo copre il chip realtime), 1y per lo storico
    # (bucket settimanali come Uptime). Default 7d.
    DEFAULT_RANGE = "7d"
    BUCKETS = {
      "24h" => { count: 48, interval: "30 minutes", seconds: 1_800 },
      "7d"  => { count: 56, interval: "3 hours",    seconds: 10_800 },
      "30d" => { count: 30, interval: "1 day",      seconds: 86_400 },
      "1y"  => { count: 52, interval: "1 week",     seconds: 604_800 }
    }.freeze

    # Colonne ammesse per i breakdown (allowlist: la colonna arriva dal controller, mai dai params).
    BREAKDOWN_COLUMNS = %w[
      browser browser_version os os_version device_type screen_class country_code
      utm_source utm_medium utm_campaign utm_term utm_content
    ].freeze

    def self.bucket_config(range) = BUCKETS.fetch(range, BUCKETS[DEFAULT_RANGE])

    # Ampiezza in secondi della finestra coperta da un range (bucket × durata bucket).
    def self.window_seconds(range)
      cfg = bucket_config(range)
      cfg[:count] * cfg[:seconds]
    end

    # Il range più stretto la cui finestra arriva a coprire `at` — serve a proporre un periodo utile
    # quando quello scelto è vuoto ma i dati esistono. nil se `at` è più vecchio del range più ampio.
    def self.range_covering(at, now: Time.current)
      return nil if at.blank?

      age = now - at
      BUCKETS.keys.find { |range| window_seconds(range) >= age }
    end

    # Scope base del range per progetto+environment: tutte le aggregazioni partono da qui.
    def self.for_range(project_id, range, environment:, now: Time.current)
      cfg = bucket_config(range)
      since = now - (cfg[:count] * cfg[:seconds])
      scope = where(project_id: project_id, occurred_at: since...now,
                    created_at: ::Ingest::EpochTime.insert_floor(since)..)
      scope = scope.where(environment: environment) if environment.present?
      scope
    end
  end
end
