# frozen_string_literal: true

module Telegram
  # Parsa un update inbound del bot e lo instrada ai comandi supportati. Lifecycle del collegamento:
  #   /start <token> → collega l'account (Telegram::LinkAccount)
  #   /start         → messaggio di benvenuto/guida (il collegamento vero passa dal deep-link della tab Telegram)
  #   /stop          → scollega (Telegram::UnlinkAccount)
  #   /start <codice> in un gruppo → collega il gruppo con argomenti dell'owner (Telegram::LinkGroup)
  # Comandi operativi (richiedono un account collegato — chat_id → account via telegram_chat_id):
  #   /aiuto|/help                     → elenco comandi (Telegram::Help)
  #   /progetti                        → progetti visibili (Telegram::ListProjects)
  #   /progetto <CHIAVE>               → progetto attivo (Telegram::SetActiveProject)
  #   /nuovo-ticket [CHIAVE] <testo>   → apre un ticket, +foto in caption (Telegram::CreateTicketFromMessage)
  #   /miei-ticket                     → i miei ticket aperti (Telegram::ListMyTickets)
  #   /ticket <CODICE>                 → stato di un ticket (Telegram::ShowTicket)
  #   /commenta <CODICE> <testo>       → commenta un ticket, +foto (Telegram::AddCommentFromMessage)
  # Il comando può stare nel testo OPPURE nella caption di una foto/documento. Comando sconosciuto →
  # rimando a /aiuto; testo libero non-comando → ignorato. Il webhook risponde comunque 200.
  class HandleUpdate < ApplicationService
    START = %r{\A/start(?:@\w+)?\s+(\S+)}
    # /start nudo (senza token), incluso il pulsante "Avvia" di Telegram: non può collegare (nessun token)
    # → rispondiamo con una guida, così il bot non resta muto ("non parte").
    BARE_START = %r{\A/start(?:@\w+)?\z}
    STOP = %r{\A/stop(?:@\w+)?\b}
    GROUP_TYPES = %w[group supergroup].freeze

    def initialize(update:)
      @update = (update || {}).with_indifferent_access
    end

    def call
      message = @update[:message] || {}
      chat_id = message.dig(:chat, :id)
      # Il comando può arrivare come testo o come caption di una foto/documento.
      text = (message[:text].presence || message[:caption].presence).to_s.strip
      return Result.ok(:ignored) if chat_id.blank? || text.blank?

      return handle_group(message[:chat], text) if GROUP_TYPES.include?(message.dig(:chat, :type))

      username = message.dig(:chat, :username) || message.dig(:from, :username)

      case text
      when START      then Telegram::LinkAccount.call(token: Regexp.last_match(1), chat_id: chat_id, username: username)
      when BARE_START then welcome(chat_id)
      when STOP       then Telegram::UnlinkAccount.call(chat_id: chat_id)
      else dispatch_command(chat_id, text, message)
      end
    end

    private

    # In un gruppo il bot ascolta solo il collegamento del gruppo con argomenti (CYRA-852): i comandi
    # personali restano nella chat privata, dove si sa chi scrive.
    def handle_group(chat, text)
      return Result.ok(:ignored) unless text.match?(START)

      Telegram::LinkGroup.call(token: text[START, 1], chat_id: chat[:id], title: chat[:title],
                               forum: chat[:is_forum] == true)
    end

    # Instrada i comandi operativi. Serve un account collegato (chat_id → account); altrimenti guida al
    # collegamento. Testo non-comando (non inizia con "/") → ignorato in silenzio (nessun rumore).
    def dispatch_command(chat_id, text, message)
      return Result.ok(:ignored) unless text.start_with?("/")

      account = Accounts::Account.find_by(telegram_chat_id: chat_id.to_s)
      return link_required(chat_id) if account.nil?

      command, rest = split_command(text)
      case command
      when "aiuto", "help"
        Telegram::Help.call(account: account, chat_id: chat_id)
      when "progetti"
        Telegram::ListProjects.call(account: account, chat_id: chat_id)
      when "progetto"
        Telegram::SetActiveProject.call(account: account, chat_id: chat_id, key: rest.split(/\s+/).first)
      when "nuovo-ticket", "nuovo_ticket"
        Telegram::CreateTicketFromMessage.call(account: account, chat_id: chat_id, args: rest, message: message)
      when "miei-ticket", "miei_ticket"
        Telegram::ListMyTickets.call(account: account, chat_id: chat_id)
      when "ticket"
        Telegram::ShowTicket.call(account: account, chat_id: chat_id, code: rest.split(/\s+/).first)
      when "commenta"
        Telegram::AddCommentFromMessage.call(account: account, chat_id: chat_id, args: rest, message: message)
      else
        unknown_command(account, chat_id)
      end
    end

    # "/nuovo-ticket@bot DRRA testo" → ["nuovo-ticket", "DRRA testo"]. Match esatto della parola-comando
    # (niente regex prefisso ambigue), @bot rimosso, args = tutto il resto.
    def split_command(text)
      head, rest = text.split(/\s+/, 2)
      command = head.sub(%r{\A/}, "").sub(/@\w+\z/, "").downcase
      [ command, rest.to_s.strip ]
    end

    def welcome(chat_id)
      Telegram::Send.call(chat_id: chat_id, text: I18n.t("telegram.start.welcome", locale: I18n.default_locale))
      Result.ok(:welcomed)
    end

    def link_required(chat_id)
      Telegram::Send.call(chat_id: chat_id, text: I18n.t("telegram.commands.link_required", locale: I18n.default_locale))
      Result.ok(:link_required)
    end

    def unknown_command(account, chat_id)
      Telegram::Send.call(chat_id: chat_id, text: I18n.t("telegram.commands.unknown", locale: account.effective_locale))
      Result.ok(:unknown)
    end
  end
end
