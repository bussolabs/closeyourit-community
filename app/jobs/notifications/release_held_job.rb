# frozen_string_literal: true

module Notifications
  # Rilascio delle email TRATTENUTE dalle quiet hours (status :held, CYRA-208). Le quiet hours sono
  # per-utente e per-organizzazione (Alerting::Preference#quiet_now?): un'email immediata scattata nel
  # silenzio nasce :held (canale email di Notifications::Deliver) invece di :skipped, così NON è più persa. Questo giro
  # ricorrente raggruppa le :held per (account, organizzazione) e, per i soli gruppi ORA fuori dal
  # silenzio, invia UN riepilogo (Notifications::DigestMailer.summary) e marca le righe :sent. I gruppi
  # ancora in silenzio restano :held per il giro successivo → consegna alla prima finestra utile.
  # Vuoto → no-op; idempotente (una volta :sent non rientrano nello scope). Ricorrente in
  # config/recurring.yml. Solo email: in-app/telegram non hanno quiet hours, quindi non producono :held.
  class ReleaseHeldJob < ApplicationJob
    queue_as :notifications

    def perform
      held = Alerting::Notification.status_held.where(via: :email)

      held.group_by { |n| [ n.account_id, n.organization_id ] }.each do |(account_id, organization_id), notifications|
        account = Accounts::Account.find_by(id: account_id)
        organization = Organizations::Organization.find_by(id: organization_id)
        next if account.nil? || organization.nil?
        next if Alerting::Preference.for(account: account, organization: organization).quiet_now?

        # CYRA-672 — l'accodamento non e' una consegna: le righe passano a :pending, «presa in
        # carico, esito non ancora noto». Serve a due cose: escono dallo scope :held, cosi' un
        # secondo giro non le rispedisce, e a segnarle consegnate e' Notifications::DeliveryObserver
        # quando il messaggio esce davvero.
        Notifications::DigestMailer.summary(account, organization, notifications).deliver_later
        Alerting::Notification.where(id: notifications.map(&:id))
                              .update_all(status: Alerting::Notification.statuses[:pending]) # rubocop:disable Rails/SkipsModelValidations
      end
    end
  end
end
