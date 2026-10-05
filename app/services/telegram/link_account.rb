# frozen_string_literal: true

module Telegram
  # Collega il chat_id Telegram di un utente al suo account, risolvendo il codice corto del deep-link
  # /start (Accounts::TelegramLinkCode, single-use). Un chat_id = un account: se era legato altrove lo
  # spostiamo. Invia una conferma nel DM (fire-and-forget). Codice invalido/scaduto → R404-TELEGRAM-001.
  class LinkAccount < ApplicationService
    def initialize(token:, chat_id:, username: nil)
      @token = token.to_s
      @chat_id = chat_id.to_s
      @username = username.presence
    end

    def call
      account = Accounts::TelegramLinkCode.consume(@token)
      return Result.err(AppError.new("Codice Telegram non valido", code: "R404-TELEGRAM-001", status: :not_found)) if account.nil?

      link!(account)
      confirm(account)
      Result.ok(account)
    end

    private

    def link!(account)
      Accounts::Account.transaction do
        # Un chat_id appartiene a un solo account: sgancia eventuali altri collegamenti a questo chat_id.
        Accounts::Account.where(telegram_chat_id: @chat_id).where.not(id: account.id)
                         .update_all(telegram_chat_id: nil, telegram_username: nil, telegram_linked_at: nil)
        account.update!(telegram_chat_id: @chat_id, telegram_username: @username, telegram_linked_at: Time.current)
      end
    end

    def confirm(account)
      Telegram::Send.call(chat_id: @chat_id,
                          text: I18n.t("telegram.link.connected", name: account.name, locale: account.effective_locale))
    end
  end
end
