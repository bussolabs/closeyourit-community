# frozen_string_literal: true

require "net/http"

module Telegram
  # Scarica un file inviato al bot (foto/documento) dalle API Telegram e lo restituisce come
  # uploadable passabile a Ticketing::AttachToTicket (che ri-sniffa il MIME reale e valida
  # tipo/dimensione). Due passi: getFile (file_id → file_path) + GET del binario. Timeout corti,
  # nessun retry: se fallisce, il ticket è comunque creato e si avvisa che la foto non è stata allegata.
  class DownloadFile < ApplicationService
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 20
    API_HOST = "https://api.telegram.org"

    def initialize(file_id:, filename: nil)
      @file_id = file_id.to_s
      @filename = filename.presence
    end

    def call
      return err("R502-TELEGRAM-002", "Bot Telegram non configurato") if token.blank?
      return err("R422-TELEGRAM-006", "file_id mancante") if @file_id.blank?

      path = file_path
      return err("R502-TELEGRAM-004", "getFile fallito") if path.blank?

      body = download(path)
      return err("R502-TELEGRAM-004", "download file fallito") if body.nil?

      Result.ok(uploadable(body, path))
    rescue StandardError => e
      Rails.logger.warn("Telegram download #{@file_id} fallito: #{e.class} #{e.message}")
      err("R502-TELEGRAM-004", "Telegram irraggiungibile")
    end

    private

    def token = Settings::Integrations.value(:telegram_bot_token).to_s

    # getFile → path relativo del file sui server Telegram.
    def file_path
      uri = URI.parse("#{API_HOST}/bot#{token}/getFile?file_id=#{CGI.escape(@file_id)}")
      response = get(uri)
      return nil unless response.code.to_i == 200

      JSON.parse(response.body).dig("result", "file_path")
    end

    def download(path)
      uri = URI.parse("#{API_HOST}/file/bot#{token}/#{path}")
      response = get(uri)
      response.code.to_i == 200 ? response.body : nil
    end

    # Wrap in un UploadedFile: risponde a tempfile/original_filename/content_type/size come richiesto
    # da AttachToTicket. Il content_type qui è indicativo (Marcel ri-sniffa i byte reali a valle).
    def uploadable(body, path)
      extension = File.extname(path.to_s)
      name = @filename || "telegram-#{@file_id}#{extension}"
      tempfile = Tempfile.new([ "telegram", extension ])
      tempfile.binmode
      tempfile.write(body)
      tempfile.rewind
      ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile, filename: name,
        type: Marcel::MimeType.for(tempfile, name: name)
      )
    end

    def get(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.request(Net::HTTP::Get.new(uri.request_uri))
    end

    def err(code, message)
      Result.err(AppError.new(message, code: code, status: :bad_gateway))
    end
  end
end
