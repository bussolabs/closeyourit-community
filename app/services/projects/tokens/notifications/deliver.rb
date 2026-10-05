# frozen_string_literal: true

module Projects
  module Tokens
    module Notifications
      # Payload dell'avviso di scadenza di una credenziale di ingest per Notifications::Deliver
      # (CYRA-716, portato sul motore comune da CYRA-744). La regola è sempre nil: l'avviso non nasce
      # da un monitoraggio configurabile ma dal giro giornaliero sulle date di scadenza. L'email riusa
      # Alerting::AlertsMailer, che rende title/body/url della notifica e non sa da quale dominio
      # arrivi — un mailer nuovo sarebbe stata la stessa pagina con un altro nome.
      class Deliver
        def self.in_app(account:, token:, content:, dedup_key:)
          ::Notifications::Deliver.in_app(
            payload: payload(account: account, token: token, content: content, dedup_key: dedup_key)
          )
        end

        def self.email(account:, token:, content:, dedup_key:, quiet: false, bucket: nil)
          ::Notifications::Deliver.email(
            payload: payload(account: account, token: token, content: content, dedup_key: dedup_key,
                             mailer: Alerting::AlertsMailer.method(:triggered)),
            quiet: quiet, bucket: bucket
          )
        end

        def self.telegram(account:, token:, content:, dedup_key:, bucket: nil)
          ::Notifications::Deliver.telegram(
            payload: payload(account: account, token: token, content: content, dedup_key: dedup_key),
            bucket: bucket
          )
        end

        def self.payload(account:, token:, content:, dedup_key:, mailer: nil)
          ::Notifications::Payload.new(
            organization: token.project.organization, project: token.project, account: account,
            subject: token, event_type: :project_token_expiring,
            title: content.title, body: content.body, url: content.url,
            dedup_key: dedup_key, mailer: mailer
          )
        end
        private_class_method :payload
      end
    end
  end
end
