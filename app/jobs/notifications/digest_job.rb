# frozen_string_literal: true

module Notifications
  # Digest periodico: raccoglie le notifiche trattenute (status :queued) di un canale (email/telegram)
  # e bucket (daily/weekly), le raggruppa per (account, organizzazione) e invia UN riepilogo per gruppo,
  # poi marca le righe :sent. Vuoto → no-op; idempotente (una volta :sent non rientrano nello scope).
  # Ricorrente in config/recurring.yml (4 istanze: email/telegram × daily/weekly).
  class DigestJob < ApplicationJob
    queue_as :notifications

    def perform(bucket, via)
      queued = Alerting::Notification.status_queued.where(via: via, digest_bucket: bucket).includes(:subject)

      queued.group_by { |n| [ n.account_id, n.organization_id ] }.each do |(account_id, organization_id), notifications|
        account = Accounts::Account.find_by(id: account_id)
        organization = Organizations::Organization.find_by(id: organization_id)
        next if account.nil? || organization.nil?

        record_outcome(notifications, deliver(via, account, organization, notifications))
      end
    end

    private

    # CYRA-672 — restituisce com'e' andata davvero, invece di lasciar credere al chiamante che sia
    # sempre andata bene. :in_volo = affidata alla posta, la conferma arrivera' da
    # Notifications::DeliveryObserver quando il messaggio esce.
    def deliver(via, account, organization, notifications)
      case via.to_s
      when "email"
        Notifications::DigestMailer.summary(account, organization, notifications).deliver_later
        :in_flight
      when "telegram"
        deliver_telegram(account, organization, notifications)
      else
        :skipped
      end
    end

    # Le righe :queued rientrano nello scope a ogni giro, quindi vanno SEMPRE tolte da li', o il
    # digest le ripropone all'infinito. Per la posta lo stato giusto e' :pending — «presa in carico,
    # esito non ancora noto»: esce dallo scope e aspetta la conferma di Notifications::DeliveryObserver.
    # Se la spedizione non riesce mai, resta :pending, che e' la verita' e non e' una ri-spedizione.
    def record_outcome(notifications, outcome)
      state = { in_flight: :pending, delivered: :sent, failed: :failed, skipped: :skipped }
              .fetch(outcome, :failed)
      attrs = { status: Alerting::Notification.statuses[state] }
      attrs[:delivered_at] = Time.current if state == :sent

      Alerting::Notification.where(id: notifications.map(&:id))
                            .update_all(attrs) # rubocop:disable Rails/SkipsModelValidations
    end

    # Il chat_id può essere sparito tra l'accodamento e il digest (l'utente si è scollegato): in tal
    # caso non si invia e le righe si chiudono come :skipped — perse, non consegnate (CYRA-672).
    # L'owner col gruppo con argomenti riceve il riassunto nel generale del gruppo (CYRA-852).
    def deliver_telegram(account, organization, notifications)
      group = Alerting::TelegramGroup.for_recipient(account: account, organization: organization)
      return :skipped unless group || account.connected_telegram?

      outcome = ::Telegram::Send.call(
        chat_id: group&.chat_id || account.telegram_chat_id,
        text: telegram_text(notifications, account.effective_locale),
        parse_mode: "HTML"
      )
      outcome.ok? ? :delivered : :failed
    end

    # Testo HTML (parse_mode "HTML"): header in grassetto nella lingua del destinatario + una riga per
    # notifica con emoji e titolo cliccabile (Notifications::TelegramText.digest_line). Gli snapshot
    # `n.title` sono già localizzati per-destinatario a monte → tutto il digest è coerente.
    def telegram_text(notifications, locale)
      header = "<b>#{I18n.t("notifications.digest.telegram.header", count: notifications.size, locale: locale)}</b>"
      lines = notifications.map { |n| Notifications::TelegramText.digest_line(n) }
      ([ header ] + lines).join("\n")
    end
  end
end
