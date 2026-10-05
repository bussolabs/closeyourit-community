# frozen_string_literal: true

module Telegram
  # /progetto CHIAVE: imposta il progetto "attivo" (account.telegram_project_id), default per
  # /nuovo-ticket senza chiave. La chiave dev'essere di un progetto visibile (ResolveProject fa il
  # controllo anti-BOLA e produce il messaggio d'errore già localizzato).
  class SetActiveProject < ApplicationService
    include Telegram::Respondable

    def initialize(account:, chat_id:, key:)
      @account = account
      @chat_id = chat_id
      @key = key.to_s.strip
    end

    def call
      return usage if @key.blank?

      result = Telegram::ResolveProject.call(account: @account, key: @key)
      unless result.ok?
        reply_text(result.error.message)
        return result
      end

      project = result.value
      @account.update!(telegram_project_id: project.id)
      reply("project.set_ok", key: project.key, name: project.name)
      Result.ok(project)
    end

    private

    def usage
      reply("project.usage")
      Result.err(AppError.new("chiave progetto mancante", code: "R422-TELEGRAM-008"))
    end
  end
end
