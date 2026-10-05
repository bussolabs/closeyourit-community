# frozen_string_literal: true

module Settings
  # GitHub App and Telegram values (CYRA-914): the one saved in Valhalla (Settings::Global, secrets
  # encrypted) wins, the environment variable is the fallback. With nothing saved, every reader gets
  # exactly the environment value it read before.
  module Integrations
    FIELDS = {
      gh_app_id: "GH_APP_ID",
      gh_app_slug: "GH_APP_SLUG",
      gh_app_client_id: "GH_APP_CLIENT_ID",
      gh_app_client_secret: "GH_APP_CLIENT_SECRET",
      gh_app_private_key: "GH_APP_PRIVATE_KEY",
      gh_webhook_secret: "GH_WEBHOOK_SECRET",
      telegram_bot_token: "TELEGRAM_BOT_TOKEN",
      telegram_bot_username: "TELEGRAM_BOT_USERNAME",
      telegram_webhook_secret: "TELEGRAM_WEBHOOK_SECRET"
    }.freeze
    SECRET_FIELDS = %i[gh_app_client_secret gh_app_private_key gh_webhook_secret
                       telegram_bot_token telegram_webhook_secret].freeze
    GITHUB_REQUIRED = %i[gh_app_id gh_app_private_key gh_app_client_id gh_app_client_secret].freeze

    module_function

    def value(field) = saved(field).presence || ENV[FIELDS.fetch(field)].presence

    def source(field)
      if saved(field).present? then :valhalla
      elsif ENV[FIELDS.fetch(field)].present? then :environment
      end
    end

    def github_configured? = GITHUB_REQUIRED.all? { |field| value(field).present? }

    def saved(field)
      FIELDS.fetch(field)
      Settings::Global.first&.public_send(field)
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      nil
    end
  end
end
