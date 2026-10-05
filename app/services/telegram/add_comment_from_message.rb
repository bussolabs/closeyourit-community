# frozen_string_literal: true

module Telegram
  # /commenta CODICE <testo>: aggiunge un commento a un ticket visibile riusando Ticketing::AddComment.
  # Eventuale foto/documento in caption viene scaricata e allegata al commento. Se il commento porta
  # solo la foto (nessun testo), il corpo cade su un'etichetta di default (il body del commento è
  # obbligatorio nel model).
  class AddCommentFromMessage < ApplicationService
    include Telegram::Respondable

    def initialize(account:, chat_id:, args:, message: nil)
      @account = account
      @chat_id = chat_id
      @args = args.to_s.strip
      @message = message
    end

    def call
      code, text = @args.split(/\s+/, 2)
      return usage if code.blank?

      result = Telegram::ResolveTicket.call(account: @account, code: code)
      unless result.ok?
        reply_text(result.error.message)
        return result
      end

      ticket = result.value
      text = text.to_s.strip
      media = telegram_media(@message)
      return empty if text.blank? && media.nil?

      add(ticket, text, media)
    end

    private

    def add(ticket, text, media)
      files = media ? download(media) : []
      comment = Ticketing::AddComment.call(
        ticket: ticket, author: @account,
        params: { body: body(text, media), files: files }
      )
      unless comment.ok?
        reply("comment.failed", error: comment.error.message)
        return comment
      end

      reply("comment.added", code: ticket.code, url: ticket_url(ticket))
      Result.ok(comment.value)
    end

    def download(media)
      file = Telegram::DownloadFile.call(file_id: media[:file_id], filename: media[:filename])
      file.ok? ? [ file.value ] : []
    end

    # body obbligatorio sul commento: testo se c'è, altrimenti etichetta di default per la foto.
    def body(text, media)
      return text if text.present?

      media ? t("comment.photo_body") : text
    end

    def usage
      reply("comment.usage")
      Result.err(AppError.new("codice ticket mancante", code: "R422-TELEGRAM-007"))
    end

    def empty
      reply("comment.empty")
      Result.err(AppError.new("testo commento mancante", code: "R422-TELEGRAM-010"))
    end
  end
end
