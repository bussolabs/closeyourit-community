# frozen_string_literal: true

module Ticketing
  # Email of a ticket notification (assignment/status change/...). The view lives under
  # app/views/mails/ticketing/ticket_notifications_mailer/ (template_path proc in ApplicationMailer).
  # In dev it goes through letter_opener; in prod it depends on the Amazon SES wiring.
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
