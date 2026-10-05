# frozen_string_literal: true

module Alerting
  # Canale di consegna ESTERNO per gli alert (oltre in-app/email/telegram-per-utente): webhook generico
  # firmato (Slack/Discord/HTTP). Org-scoped, agganciato alle regole via Alerting::RuleChannel (una
  # regola senza canali consegna solo in-app/email + Telegram personale dei destinatari). `kind` resta
  # un discriminator (enum legittimo, rules/lookup-tables.md) per future estensioni. Il vecchio kind
  # `telegram` (bot BYO org-level) è stato rimosso: le notifiche Telegram ora sono per-utente (bot
  # ufficiale, canale Telegram::) — vedi la fase notifiche/preferenze.
  class Channel < ApplicationRecord
    self.table_name = "alerting_channels"

    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :alerting_channels
    belongs_to :created_by, class_name: "Accounts::Account", optional: true
    has_many :rule_channels, class_name: "Alerting::RuleChannel", foreign_key: :channel_id,
             inverse_of: :channel, dependent: :destroy
    has_many :rules, through: :rule_channels

    enum :kind, { webhook: 0 }, prefix: :kind

    # Secret di firma (HMAC) del webhook: cifrato at-rest (AR::Encryption, non-deterministic — non si
    # cerca per valore). Prima viveva plaintext in config["secret"]; ora colonna dedicata cifrata.
    encrypts :webhook_secret

    normalizes :name, with: ->(value) { value.to_s.strip }

    validates :name, presence: true, uniqueness: { scope: :organization_id }
    validate :webhook_config_valid

    scope :enabled, -> { where(enabled: true) }

    # webhook_url resta nel config JSONB (non segreto); webhook_secret è la colonna cifrata.
    # webhook_secret? (present?) è generato da ActiveRecord sull'attributo → usato dalla view.
    def webhook_url = config["url"].to_s

    private

    # URL https obbligatoria e NON interna (anti-SSRF a config-time; il deliver ri-verifica).
    def webhook_config_valid
      errors.add(:config, :webhook_url_invalid) unless NetworkGuard.safe_url?(webhook_url)
    end
  end
end
