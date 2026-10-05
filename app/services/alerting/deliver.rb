# frozen_string_literal: true

module Alerting
  # Payload del dominio avvisi per Notifications::Deliver (CYRA-744): chi riceve, cosa legge e con
  # quale chiave si riconosce il doppione. È l'unico dominio con una REGOLA dietro la notifica
  # (rule) e con l'elenco esteso dei dettagli (details): entrambi arrivano da qui e da nessun altro.
  # La consegna vera — riga, dedup, spedizione, stato — è tutta nel motore comune.
  class Deliver
    def self.in_app(rule:, account:, event_type:, subject:, content:, dedup_key:)
      ::Notifications::Deliver.in_app(
        payload: payload(rule: rule, account: account, event_type: event_type, subject: subject,
                         content: content, dedup_key: dedup_key)
      )
    end

    def self.email(rule:, account:, event_type:, subject:, content:, dedup_key:, quiet: false, bucket: nil)
      ::Notifications::Deliver.email(
        payload: payload(rule: rule, account: account, event_type: event_type, subject: subject,
                         content: content, dedup_key: dedup_key,
                         mailer: Alerting::AlertsMailer.method(:triggered)),
        quiet: quiet, bucket: bucket
      )
    end

    def self.telegram(rule:, account:, event_type:, subject:, content:, dedup_key:, bucket: nil)
      ::Notifications::Deliver.telegram(
        payload: payload(rule: rule, account: account, event_type: event_type, subject: subject,
                         content: content, dedup_key: dedup_key),
        bucket: bucket
      )
    end

    # Canale esterno della regola: nessun destinatario, nessuna riga — passa dal motore senza payload.
    def self.webhook(channel:, event_type:, subject:, content:)
      ::Notifications::Deliver.webhook(channel: channel, event_type: event_type, subject: subject, content: content)
    end

    def self.payload(rule:, account:, event_type:, subject:, content:, dedup_key:, mailer: nil)
      ::Notifications::Payload.new(
        organization: rule.organization, project: content.project, account: account,
        subject: subject, rule: rule, event_type: event_type,
        title: content.title, body: content.body, url: content.url, details: content.details,
        dedup_key: dedup_key, mailer: mailer
      )
    end
    private_class_method :payload
  end
end
