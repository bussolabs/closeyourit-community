# frozen_string_literal: true

module Telegram
  # Utility di risposta condivise dai comandi inbound. Ogni comando tiene @account e @chat_id:
  # reply/t rispondono nel DM nella lingua dell'utente (account.effective_locale). MAI HTML
  # (parse_mode nil): i testi contengono titoli/chiavi utente non escapati → testo semplice, e
  # Telegram rende cliccabili gli URL da solo.
  module Respondable
    private

    def reply(key, **args)
      reply_text(t(key, **args))
    end

    # Risponde con un testo GIÀ localizzato (es. il message di un AppError da ResolveProject/ResolveTicket).
    def reply_text(text)
      Telegram::Send.call(chat_id: @chat_id, text: text)
    end

    def t(key, **args)
      I18n.t("telegram.#{key}", locale: reply_locale, **args)
    end

    def reply_locale
      @account&.effective_locale || I18n.default_locale
    end

    def app_base_url
      App::Host.base_url
    end

    def ticket_url(ticket)
      "#{app_base_url}/member/tickets/#{ticket.id}"
    end

    # Estrae il file allegato a un update Telegram: foto (prende la risoluzione più grande = ultima)
    # o documento. Ritorna { file_id:, filename: } oppure nil. Album/media_group (foto multiple in
    # update separati) fuori v1 → una sola foto/documento per messaggio.
    def telegram_media(message)
      message = (message || {}).with_indifferent_access
      if (photos = message[:photo]).present?
        { file_id: Array(photos).last[:file_id], filename: nil }
      elsif (document = message[:document]).present?
        { file_id: document[:file_id], filename: document[:file_name] }
      end
    end
  end
end
