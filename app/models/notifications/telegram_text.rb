# frozen_string_literal: true

require "cgi"

module Notifications
  # Testo HTML del messaggio Telegram di una notifica. Condiviso dal canale Telegram di Notifications::Deliver e dal
  # digest → va inviato con parse_mode "HTML" (Telegram::Send). Formato:
  #   {emoji} <b>{titolo}</b>
  #   <blockquote>{corpo}</blockquote>          (solo se il corpo è presente)
  #   📄 <a href="{url assoluto}">{label}</a>    (solo se l'url è presente)
  # title/body/url sono input arbitrari (nomi attore, testo commento) → SEMPRE escapati (CGI.escapeHTML);
  # la label del link viene da i18n (fidata) → non escapata.
  module TelegramText
    LINK_ICON = "📄"
    # Telegram rejects messages over 4096 visible characters (CYRA-874): room is left for emoji and link.
    MAX_TITLE = 256
    MAX_BODY = 3500

    def self.for(notification)
      lines = [ "#{TelegramEmoji.for(notification.event_type)} <b>#{esc(notification.title.to_s.truncate(MAX_TITLE))}</b>" ]
      lines << "<blockquote>#{esc(notification.body.truncate(MAX_BODY))}</blockquote>" if notification.body.present?
      lines << link_line(notification) if notification.url.present?
      lines.join("\n")
    end

    # Riga singola del digest: {emoji} {titolo cliccabile} (solo emoji + titolo se manca l'url).
    def self.digest_line(notification)
      emoji = TelegramEmoji.for(notification.event_type)
      title = esc(notification.title)
      return "#{emoji} #{title}" if notification.url.blank?

      "#{emoji} <a href=\"#{esc(absolute_url(notification.url))}\">#{title}</a>"
    end

    def self.link_line(notification)
      label = I18n.t("notifications.telegram.link.#{TelegramEmoji.domain_for(notification.event_type)}",
                     locale: notification.account&.effective_locale)
      "#{LINK_ICON} <a href=\"#{esc(absolute_url(notification.url))}\">#{label}</a>"
    end

    def self.absolute_url(url)
      url.to_s.start_with?("http") ? url.to_s : "#{base_url}#{url}"
    end

    def self.base_url
      App::Host.base_url
    end

    def self.esc(value)
      CGI.escapeHTML(value.to_s)
    end

    private_class_method :link_line, :absolute_url, :base_url, :esc
  end
end
