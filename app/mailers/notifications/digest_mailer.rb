# frozen_string_literal: true

module Notifications
  # Email di riepilogo (digest) delle notifiche trattenute per la cadenza daily/weekly. La view vive
  # sotto app/views/mails/notifications/digest_mailer/ (template_path proc in ApplicationMailer).
  class DigestMailer < ApplicationMailer
    def summary(account, organization, notifications)
      @account = account
      @organization = organization
      @notifications = notifications
      track_delivery(notifications)

      mail to: account.email,
           subject: t("notifications.digest.mailer.summary", count: notifications.size)
    end
  end
end
