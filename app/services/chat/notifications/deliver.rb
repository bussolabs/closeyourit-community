# frozen_string_literal: true

module Chat
  module Notifications
    # Payload del dominio chat per Notifications::Deliver (CYRA-744): il soggetto è il messaggio e il
    # progetto c'è solo per i canali di progetto — un DM o un canale di team non ne ha. È l'unico
    # dominio che espone il doppione a un chiamante HTTP, quindi l'esito è un AppError e non il
    # simbolo :duplicate. La consegna vera è tutta nel motore comune.
    class Deliver
      def self.in_app(account:, message:, organization:, event_type:, content:, dedup_key:)
        ::Notifications::Deliver.in_app(
          payload: payload(account: account, message: message, organization: organization,
                           event_type: event_type, content: content, dedup_key: dedup_key)
        )
      end

      def self.email(account:, message:, organization:, event_type:, content:, dedup_key:, quiet: false, bucket: nil)
        ::Notifications::Deliver.email(
          payload: payload(account: account, message: message, organization: organization,
                           event_type: event_type, content: content, dedup_key: dedup_key,
                           mailer: Chat::MessageNotificationsMailer.method(:notify)),
          quiet: quiet, bucket: bucket
        )
      end

      def self.telegram(account:, message:, organization:, event_type:, content:, dedup_key:, bucket: nil)
        ::Notifications::Deliver.telegram(
          payload: payload(account: account, message: message, organization: organization,
                           event_type: event_type, content: content, dedup_key: dedup_key),
          bucket: bucket
        )
      end

      def self.payload(account:, message:, organization:, event_type:, content:, dedup_key:, mailer: nil)
        conversation = message.conversation

        ::Notifications::Payload.new(
          organization: organization, project: conversation.kind_project? ? conversation.contextable : nil,
          account: account, subject: message, event_type: event_type,
          title: content.title, body: content.body, url: content.url,
          dedup_key: dedup_key, mailer: mailer,
          duplicate_error: AppError.new(I18n.t("chat.errors.duplicate_notification"),
                                        code: "R409-CHAT-011", status: :conflict)
        )
      end
      private_class_method :payload
    end
  end
end
