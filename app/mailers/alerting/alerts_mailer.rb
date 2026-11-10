# frozen_string_literal: true

module Alerting
  # Email of an alert. The view lives under app/views/mails/alerting/alerts_mailer/ (template_path proc
  # in ApplicationMailer). In dev it goes through letter_opener; in prod it depends on the Amazon SES wiring.
  class AlertsMailer < ApplicationMailer
    # CYRA-480: il nome dell'evento arriva dal catalogo unico (Notifications::Catalog), lo stesso che
    # usano le regole e le impostazioni personali — nell'email non può comparire un terzo vocabolario.
    helper AlertingHelper

    def triggered(notification)
      @notification = notification
      @account = notification.account
      track_delivery(notification)

      mail to: @account.email,
           subject: t("alerting.alerts.mailer.triggered.subject", title: notification.title)
    end
  end
end
