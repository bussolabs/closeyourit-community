# frozen_string_literal: true

module Telegram
  # Crea un argomento nel gruppo e ne torna il numero (message_thread_id). Serve che il gruppo abbia gli
  # argomenti attivi e che il bot possa gestirli; altrimenti Result.err e l'avviso va nel generale (CYRA-852).
  class CreateForumTopic < ApplicationService
    def initialize(chat_id:, name:, icon: nil)
      @chat_id = chat_id.to_s
      @name = name.to_s.first(128)
      @icon = icon
    end

    def call
      response = Telegram::Send.api_post("createForumTopic", chat_id: @chat_id, name: @name, icon_custom_emoji_id: @icon)
      thread_id = JSON.parse(response.body.to_s).dig("result", "message_thread_id") if response.code.to_i == 200
      return Result.ok(thread_id) if thread_id

      Rails.logger.warn("Telegram createForumTopic chat #{@chat_id} → HTTP #{response.code}")
      err
    rescue StandardError => e
      Rails.logger.warn("Telegram createForumTopic chat #{@chat_id} fallito: #{e.class} #{e.message}")
      err
    end

    private

    def err
      Result.err(AppError.new("Argomento Telegram non creato", code: "R502-TELEGRAM-011", status: :bad_gateway))
    end
  end
end
