# frozen_string_literal: true

module Chat
  # Email di una notifica di chat (nuovo messaggio / menzione). La view vive sotto
  # app/views/mails/chat/message_notifications_mailer/ (template_path proc in ApplicationMailer). In
  # dev parte via letter_opener; in prod dipende dal cablaggio Resend.
  class MessageNotificationsMailer < ApplicationMailer
    def notify(notification)
      @notification = notification
      @account = notification.account
      @message = notification.subject
      @conversation = @message&.conversation
      track_delivery(notification)

      mail to: @account.email,
           subject: t("chat.message_notifications.mailer.notify.subject", name: @message&.author&.name)
    end
  end
end
