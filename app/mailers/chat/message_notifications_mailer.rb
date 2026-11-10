# frozen_string_literal: true

module Chat
  # Email of a chat notification (new message / mention). The view lives under
  # app/views/mails/chat/message_notifications_mailer/ (template_path proc in ApplicationMailer). In
  # dev it goes through letter_opener; in prod it depends on the Amazon SES wiring.
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
