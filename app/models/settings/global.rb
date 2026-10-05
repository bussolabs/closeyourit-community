# frozen_string_literal: true

module Settings
  # Configurazione globale di sistema a riga singola (gestita dal god in Valhalla): la retention di
  # default di log e analytics (livello più alto della gerarchia god → org → progetto) e gli
  # interruttori per-servizio delle funzioni AI (vedi Ai::Feature).
  class Global < ApplicationRecord
    self.table_name = "settings_global"

    # Le colonne degli interruttori AI, una per servizio di Ai::Feature::KEYS. Elencate qui perché
    # sono il contratto fra il model, i parametri permessi del controller e la view.
    AI_SWITCH_COLUMNS = Ai::Feature::KEYS.map { |key| :"ai_#{key}_enabled" }.freeze

    # Il default globale è OBBLIGATORIO (il god non lo svuota): org/progetto possono ereditare,
    # ma il livello di sistema deve sempre avere un valore (la riga è seedata a 14).
    validates :artifacts_retention_days, presence: true, numericality: { only_integer: true, in: 1..365 }
    validates :crashes_retention_days, presence: true, numericality: { only_integer: true, in: 1..365 }
    validates :session_health_retention_days, presence: true, numericality: { only_integer: true, in: 1..365 }
    validates :measurements_retention_days, presence: true, numericality: { only_integer: true, in: 1..365 }
    validates :traces_retention_days, presence: true, numericality: { only_integer: true, in: 1..365 }
    validates :logs_retention_days,
              presence: true, numericality: { only_integer: true, in: 1..365 }
    # Retention pageview (analytics): stesso contratto dei log, range più lungo (storico per natura).
    validates :analytics_retention_days,
              presence: true, numericality: { only_integer: true, in: 1..730 }
    # Errori/performance/server (CYRA-159): stesso contratto dei log — sempre valorizzati al livello
    # di sistema. I server non hanno livello progetto (org-scoped nel data model), ma il default di
    # sistema resta comunque obbligatorio come gli altri.
    validates :errors_retention_days,
              presence: true, numericality: { only_integer: true, in: 1..365 }
    validates :performance_retention_days,
              presence: true, numericality: { only_integer: true, in: 1..365 }
    validates :servers_retention_days,
              presence: true, numericality: { only_integer: true, in: 1..365 }
    # Disponibilità: governa solo il daily (storico), range più lungo come analytics.
    validates :uptime_retention_days,
              presence: true, numericality: { only_integer: true, in: 1..730 }

    # AI provider picked in Valhalla (Ai::Configuration, CYRA-916). NULL = read the environment.
    AI_PROVIDER_COLUMNS = %i[ai_provider ai_base_url ai_api_key ai_chat_model ai_embedding_model
                             ai_embedding_dimensions ai_transcription_model ai_rerank_base_url
                             ai_rerank_api_key ai_rerank_model].freeze

    encrypts :ai_api_key
    encrypts :ai_rerank_api_key
    # GitHub App and Telegram secrets set from Valhalla (Settings::Integrations, CYRA-914).
    encrypts :gh_app_client_secret, :gh_app_private_key, :gh_webhook_secret,
             :telegram_bot_token, :telegram_webhook_secret

    # Never serialized: a render json, a log line or an error report would carry them (CYRA-914 D13).
    SECRET_COLUMNS = (%w[ai_api_key ai_rerank_api_key] + Settings::Integrations::SECRET_FIELDS.map(&:to_s)).freeze

    def serializable_hash(options = nil)
      options = (options || {}).dup
      options[:except] = Array(options[:except]).map(&:to_s) | SECRET_COLUMNS
      super
    end

    validates :ai_provider, inclusion: { in: Ai::Configuration::PROVIDERS }, allow_nil: true
    validates :ai_api_key, presence: true, if: -> { ai_provider.present? }
    validates :ai_base_url, :ai_chat_model, presence: true, if: -> { ai_provider == "custom" }
    validates :ai_base_url, :ai_rerank_base_url, format: { with: %r{\Ahttps?://\S+\z}i }, allow_blank: true
    validates :ai_embedding_dimensions,
              numericality: { only_integer: true, in: 1..Ai::Configuration::MAX_EMBEDDING_DIMENSIONS },
              presence: { if: -> { ai_provider == "custom" && ai_embedding_model.present? } },
              allow_nil: true

    # Monthly AI chat tokens per organization (CYRA-914); empty = no cap.
    validates :ai_org_monthly_token_cap, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

    after_commit { Ai::Configuration.reset! }

    # La (unica) riga di configurazione: creata coi default al primo accesso (idempotente).
    def self.instance
      first || create!(
        artifacts_retention_days: 30,
        crashes_retention_days: 30,
        session_health_retention_days: 30,
        measurements_retention_days: 14,
        traces_retention_days: 14,
        logs_retention_days: Logs::Constants::RETENTION_DEFAULT_DAYS,
        analytics_retention_days: Analytics::Constants::RETENTION_DEFAULT_DAYS,
        errors_retention_days: Errors::Constants::RETENTION_DEFAULT_DAYS,
        performance_retention_days: Metrics::Constants::RETENTION_DEFAULT_DAYS,
        servers_retention_days: Servers::Constants::RETENTION_DEFAULT_DAYS,
        uptime_retention_days: Uptime::Constants::RETENTION_DEFAULT_DAYS
      )
    end
  end
end
