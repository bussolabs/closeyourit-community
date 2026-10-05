# frozen_string_literal: true

module Telegram
  # /aiuto (o /help): elenca i comandi disponibili nella lingua dell'utente.
  class Help < ApplicationService
    include Telegram::Respondable

    def initialize(account:, chat_id:)
      @account = account
      @chat_id = chat_id
    end

    def call
      reply("help.body")
      Result.ok(:helped)
    end
  end
end
