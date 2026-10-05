# frozen_string_literal: true

module Ticketing
  module Notifications
    # Payload del dominio ticket per Notifications::Deliver (CYRA-744): il soggetto è il ticket, il
    # progetto è il suo, e la regola è sempre nil — l'avviso nasce da un evento sul ticket, non da
    # una regola di monitoraggio configurabile. La consegna vera è tutta nel motore comune.
    class Deliver
      def self.in_app(account:, ticket:, organization:, event_type:, content:, dedup_key:)
        ::Notifications::Deliver.in_app(
          payload: payload(account: account, ticket: ticket, organization: organization,
                           event_type: event_type, content: content, dedup_key: dedup_key)
        )
      end

      def self.email(account:, ticket:, organization:, event_type:, content:, dedup_key:, quiet: false, bucket: nil)
        ::Notifications::Deliver.email(
          payload: payload(account: account, ticket: ticket, organization: organization,
                           event_type: event_type, content: content, dedup_key: dedup_key,
                           mailer: Ticketing::TicketNotificationsMailer.method(:notify)),
          quiet: quiet, bucket: bucket
        )
      end

      def self.telegram(account:, ticket:, organization:, event_type:, content:, dedup_key:, bucket: nil)
        ::Notifications::Deliver.telegram(
          payload: payload(account: account, ticket: ticket, organization: organization,
                           event_type: event_type, content: content, dedup_key: dedup_key),
          bucket: bucket
        )
      end

      def self.payload(account:, ticket:, organization:, event_type:, content:, dedup_key:, mailer: nil)
        ::Notifications::Payload.new(
          organization: organization, project: ticket.project, account: account,
          subject: ticket, event_type: event_type,
          title: content.title, body: content.body, url: content.url,
          dedup_key: dedup_key, mailer: mailer
        )
      end
      private_class_method :payload
    end
  end
end
