# frozen_string_literal: true

module Ticketing
  # Email di una notifica ticket (assegnazione/cambio stato/...). La view vive sotto
  # app/views/mails/ticketing/ticket_notifications_mailer/ (template_path proc in ApplicationMailer).
  # In dev parte via letter_opener; in prod dipende dal cablaggio Resend.
  class TicketNotificationsMailer < ApplicationMailer
    def notify(notification)
      @notification = notification
      @account = notification.account
      @ticket = notification.subject
      track_delivery(notification)

      mail to: @account.email,
           subject: t("ticketing.ticket_notifications.mailer.notify.subject",
                      code: @ticket.code, title: @ticket.title)
    end
  end
end
