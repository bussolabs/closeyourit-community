# frozen_string_literal: true

module Secrets
  # Email of a vault notification (CYRA-138, phase 4: A2 rotation, part B failed deletion/sync). The
  # view lives under app/views/mails/secrets/secret_notifications_mailer/ (template_path proc in
  # ApplicationMailer). In dev it goes through letter_opener; in prod it depends on the Amazon SES wiring.
  #
  # Il subject della notifica è polimorfico: Secrets::Variable per la rotazione (A2, ancora viva) o
  # Projects::Project per cancellazione/sync falliti (B, nessuna variabile viva). @variable resta nil
  # fuori dal caso Variable — la view mostra il dettaglio extra (pill nome + riga ambiente) SOLO
  # quando è presente; title/body (già uno snapshot completo via Content) bastano per gli altri eventi.
  class SecretNotificationsMailer < ApplicationMailer
    def notify(notification)
      @notification = notification
      @account = notification.account
      @variable = notification.subject if notification.subject.is_a?(Secrets::Variable)
      track_delivery(notification)

      mail to: @account.email,
           subject: t("secrets.secret_notifications.mailer.notify.subject",
                      title: notification.title)
    end
  end
end
