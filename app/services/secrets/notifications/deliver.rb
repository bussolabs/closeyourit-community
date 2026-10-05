# frozen_string_literal: true

module Secrets
  module Notifications
    # Payload del dominio vault per Notifications::Deliver (CYRA-744): il soggetto e il progetto sono
    # ESPLICITI perché non tutti gli eventi hanno una variabile viva da cui ricavarli — la
    # cancellazione la distrugge, il sync fallito non ne ha una. `variable:` resta un alias di comodo,
    # MAI rimosso, per il promemoria di rotazione (CYRA-138 A2): passata così, soggetto e progetto
    # vengono da lei e il chiamante non cambia. La consegna vera è tutta nel motore comune.
    class Deliver
      def self.in_app(account:, organization:, event_type:, content:, dedup_key:,
                      variable: nil, subject: nil, project: nil)
        ::Notifications::Deliver.in_app(
          payload: payload(account: account, organization: organization, event_type: event_type,
                           content: content, dedup_key: dedup_key,
                           variable: variable, subject: subject, project: project)
        )
      end

      def self.email(account:, organization:, event_type:, content:, dedup_key:,
                     variable: nil, subject: nil, project: nil, quiet: false, bucket: nil)
        ::Notifications::Deliver.email(
          payload: payload(account: account, organization: organization, event_type: event_type,
                           content: content, dedup_key: dedup_key,
                           variable: variable, subject: subject, project: project,
                           mailer: Secrets::SecretNotificationsMailer.method(:notify)),
          quiet: quiet, bucket: bucket
        )
      end

      def self.telegram(account:, organization:, event_type:, content:, dedup_key:,
                        variable: nil, subject: nil, project: nil, bucket: nil)
        ::Notifications::Deliver.telegram(
          payload: payload(account: account, organization: organization, event_type: event_type,
                           content: content, dedup_key: dedup_key,
                           variable: variable, subject: subject, project: project),
          bucket: bucket
        )
      end

      def self.payload(account:, organization:, event_type:, content:, dedup_key:,
                       variable: nil, subject: nil, project: nil, mailer: nil)
        ::Notifications::Payload.new(
          organization: organization, project: project || variable&.project, account: account,
          subject: subject || variable, event_type: event_type,
          title: content.title, body: content.body, url: content.url,
          dedup_key: dedup_key, mailer: mailer
        )
      end
      private_class_method :payload
    end
  end
end
