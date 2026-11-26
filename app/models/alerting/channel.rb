# frozen_string_literal: true

module Alerting
  # Canale di consegna ESTERNO per gli alert (oltre in-app/email/telegram-per-utente). Org-scoped,
  # agganciato alle regole via Alerting::RuleChannel (una regola senza canali consegna solo in-app/email
  # + Telegram personale dei destinatari). Due tipi: webhook generico firmato (Slack/Discord/HTTP) e
  # app Slack dei Puckies, che scrive in un canale Slack con i pulsanti d'azione (CYRA-1156).
  class Channel < ApplicationRecord
    self.table_name = "alerting_channels"

    # A Slack channel id: public (C…) or private (G…), always with digits, so a name typed in
    # capitals («GENERAL») is not taken for a code. CYRA-1156
    SLACK_CHANNEL_FORMAT = /\A[CG](?=[A-Z0-9]*[0-9])[A-Z0-9]{6,}\z/

    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :alerting_channels
    belongs_to :created_by, class_name: "Accounts::Account", optional: true
    has_many :rule_channels, class_name: "Alerting::RuleChannel", foreign_key: :channel_id,
             inverse_of: :channel, dependent: :destroy
    has_many :rules, through: :rule_channels
    has_many :slack_messages, class_name: "Alerting::SlackMessage", foreign_key: :channel_id,
             inverse_of: :channel, dependent: :delete_all

    enum :kind, { webhook: 0, slack_app: 1 }, prefix: :kind

    # Secret di firma (HMAC) del webhook: cifrato at-rest (AR::Encryption, non-deterministic — non si
    # cerca per valore). Prima viveva plaintext in config["secret"]; ora colonna dedicata cifrata.
    encrypts :webhook_secret

    normalizes :name, with: ->(value) { value.to_s.strip }

    validates :name, presence: true, uniqueness: { scope: :organization_id }
    validate :webhook_config_valid, if: :kind_webhook?
    validate :slack_config_valid, if: :kind_slack_app?

    scope :enabled, -> { where(enabled: true) }

    # webhook_url resta nel config JSONB (non segreto); webhook_secret è la colonna cifrata.
    # webhook_secret? (present?) è generato da ActiveRecord sull'attributo → usato dalla view.
    def webhook_url = config["url"].to_s

    def slack_channel = config["slack_channel"].to_s

    # What the list shows as the destination of the channel.
    def target = kind_slack_app? ? slack_channel : webhook_url

    private

    # URL https obbligatoria e NON interna (anti-SSRF a config-time; il deliver ri-verifica).
    def webhook_config_valid
      errors.add(:config, :webhook_url_invalid) unless NetworkGuard.safe_url?(webhook_url)
    end

    def slack_config_valid
      errors.add(:config, :slack_channel_invalid) unless SLACK_CHANNEL_FORMAT.match?(slack_channel)
    end
  end
end
