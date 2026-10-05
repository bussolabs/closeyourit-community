# frozen_string_literal: true

module Telegram
  # Scollega il chat_id Telegram (comando /stop dal bot): azzera il collegamento sull'account che lo
  # possiede e conferma nel DM. Idempotente: nessun account collegato a quel chat_id → no-op ok.
  class UnlinkAccount < ApplicationService
    def initialize(chat_id:)
      @chat_id = chat_id.to_s
    end

    def call
      account = Accounts::Account.find_by(telegram_chat_id: @chat_id)
      return Result.ok(nil) if account.nil?

      # locale letto PRIMA dell'azzeramento: update! non tocca `locale` (vive in preferences jsonb),
      # ma la conferma va nella lingua dell'utente che si sta scollegando.
      locale = account.effective_locale
      account.update!(telegram_chat_id: nil, telegram_username: nil, telegram_linked_at: nil)
      Telegram::Send.call(chat_id: @chat_id, text: I18n.t("telegram.link.disconnected", locale: locale))
      Result.ok(account)
    end
  end
end
