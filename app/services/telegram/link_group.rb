# frozen_string_literal: true

module Telegram
  # Collega il gruppo con argomenti all'organizzazione del codice (/start CODICE scritto nel gruppo,
  # CYRA-852). Solo l'owner attuale può; un gruppo senza argomenti viene rifiutato con la spiegazione.
  # Ricollegare lo stesso gruppo tiene gli argomenti già creati (e ne aggiorna le icone), un gruppo
  # diverso riparte da zero.
  class LinkGroup < ApplicationService
    def initialize(token:, chat_id:, title: nil, forum: false)
      @token = token.to_s
      @chat_id = chat_id.to_s
      @title = title.presence
      @forum = forum
    end

    def call
      code = Accounts::TelegramLinkCode.consume_for_group(@token)
      return err("Codice Telegram non valido", "R404-TELEGRAM-001", :not_found) if code.nil?

      account = code.account
      organization = code.organization
      return refuse(:not_owner, account, "R403-TELEGRAM-012", :forbidden) unless organization.owner_membership&.account_id == account.id
      return refuse(:not_forum, account, "R422-TELEGRAM-013", :unprocessable_content) unless @forum

      group = link!(organization, account)
      refresh_icons(group)
      reply(:connected, account, organization: organization.name)
      Result.ok(organization)
    end

    private

    def link!(organization, account)
      group = Alerting::TelegramGroup.find_or_initialize_by(organization: organization)
      group.topics = {} if group.chat_id != @chat_id
      group.update!(account: account, chat_id: @chat_id, title: @title)
      group
    end

    # Ricollegare lo stesso gruppo rimette le icone attuali sugli argomenti già creati (CYRA-865).
    # Esito ignorato: un'icona non aggiornata non ferma il collegamento.
    def refresh_icons(group)
      group.topics.each do |key, thread_id|
        Telegram::Send.api_post("editForumTopic", chat_id: @chat_id, message_thread_id: thread_id,
                                                  icon_custom_emoji_id: Alerting::TelegramGroup.topic_icon(key))
      rescue StandardError => e
        Rails.logger.warn("Telegram editForumTopic chat #{@chat_id} fallito: #{e.class} #{e.message}")
      end
    end

    def refuse(reason, account, code, status)
      reply(reason, account)
      err(reason.to_s, code, status)
    end

    def reply(key, account, **args)
      Telegram::Send.call(chat_id: @chat_id,
                          text: I18n.t("telegram.group.#{key}", locale: account.effective_locale, **args))
    end

    def err(message, code, status)
      Result.err(AppError.new(message, code: code, status: status))
    end
  end
end
