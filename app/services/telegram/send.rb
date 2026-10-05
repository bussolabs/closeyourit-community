# frozen_string_literal: true

require "net/http"

module Telegram
  # Trasporto in uscita verso il bot ufficiale CloseYourIt: sendMessage al chat_id PERSONALE dell'utente.
  # Token globale da ENV (TELEGRAM_BOT_TOKEN). Fire-and-forget come il canale Telegram delle notifiche: timeout
  # corti, niente retry, errori loggati. Usato sia dalla conferma di collegamento (webhook) sia dalla
  # consegna delle notifiche (Notifications::Deliver).
  #
  # parse_mode: nil (default) → testo plain, usato dai messaggi lifecycle statici (welcome/link/unlink).
  # parse_mode: "HTML" → passato da Notifications::Deliver e dal digest, che costruiscono testo HTML
  # (grassetto/blockquote/link) con Notifications::TelegramText (input arbitrario già escapato a monte).
  class Send < ApplicationService
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 5
    API_HOST = "https://api.telegram.org"

    # message_thread_id: l'argomento di un gruppo con argomenti (CYRA-852); nil = chat senza argomenti.
    def initialize(chat_id:, text:, parse_mode: nil, message_thread_id: nil)
      @chat_id = chat_id.to_s
      @text = text.to_s
      @parse_mode = parse_mode
      @message_thread_id = message_thread_id
    end

    # Una chiamata all'API del bot. Condivisa con chi deve leggere la risposta (Telegram::CreateForumTopic).
    def self.token = Settings::Integrations.value(:telegram_bot_token).to_s

    def self.api_post(method, body)
      uri = URI.parse("#{API_HOST}/bot#{token}/#{method}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request.body = body.compact.to_json
      http.request(request)
    end

    def call
      return err("R502-TELEGRAM-002", "Bot Telegram non configurato") if token.blank?
      return err("R502-TELEGRAM-003", "Chat Telegram mancante") if @chat_id.blank?

      response = post
      return Result.ok(true) if response.code.to_i == 200

      Rails.logger.warn("Telegram send chat #{@chat_id} → HTTP #{response.code}")
      # A 400 also covers text too long or unreadable HTML: only a missing topic may reopen it (CYRA-874).
      return err("R502-TELEGRAM-014", "Telegram topic not found") if response.code.to_i == 400 && topic_gone?(response)
      return err("R502-TELEGRAM-010", "Telegram ha rifiutato il messaggio") if response.code.to_i == 400

      err("R502-TELEGRAM-001", "Telegram HTTP #{response.code}")
    rescue StandardError => e
      Rails.logger.warn("Telegram send chat #{@chat_id} fallito: #{e.class} #{e.message}")
      err("R502-TELEGRAM-001", "Telegram irraggiungibile")
    end

    private

    def token = self.class.token

    def topic_gone?(response)
      JSON.parse(response.body.to_s)["description"].to_s.match?(/thread not found|TOPIC_DELETED/i)
    rescue JSON::ParserError
      false
    end

    def err(code, message)
      Result.err(AppError.new(message, code: code, status: :bad_gateway))
    end

    def post
      self.class.api_post("sendMessage", chat_id: @chat_id, message_thread_id: @message_thread_id, text: @text,
                                         disable_web_page_preview: true, parse_mode: @parse_mode)
    end
  end
end
