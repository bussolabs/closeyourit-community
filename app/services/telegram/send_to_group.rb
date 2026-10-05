# frozen_string_literal: true

module Telegram
  # Manda un avviso nel gruppo dell'owner, dentro l'argomento del suo tipo (CYRA-852). L'argomento
  # nasce qui la prima volta; se non si riesce a crearlo, l'avviso va nel generale del gruppo.
  class SendToGroup < ApplicationService
    def initialize(group:, event_type:, text:)
      @group = group
      @key = Alerting::TelegramGroup.topic_key(event_type)
      @text = text
    end

    def call
      thread_id = topic_id
      outcome = deliver(thread_id)
      return outcome unless thread_id && outcome.error&.code == "R502-TELEGRAM-014"

      # Someone deleted the topic by hand: open a new one and retry, once.
      forget_topic
      deliver(topic_id)
    end

    private

    def deliver(thread_id)
      Telegram::Send.call(chat_id: @group.chat_id, text: @text, parse_mode: "HTML", message_thread_id: thread_id)
    end

    # Il lock evita due argomenti uguali quando due avvisi dello stesso tipo arrivano insieme.
    def topic_id
      @group.with_lock do
        @group.topics[@key] || create_topic
      end
    end

    def create_topic
      name = I18n.with_locale(@group.account.effective_locale) { Alerting::TelegramGroup.topic_name(@key) }
      created = Telegram::CreateForumTopic.call(chat_id: @group.chat_id, name: name,
                                                icon: Alerting::TelegramGroup.topic_icon(@key))
      return unless created.ok?

      @group.update!(topics: @group.topics.merge(@key => created.value))
      created.value
    end

    def forget_topic
      @group.with_lock { @group.update!(topics: @group.topics.except(@key)) }
    end
  end
end
