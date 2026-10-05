# frozen_string_literal: true

module Helpdesk
  # The answer a person of the team wrote to a visitor (CYRA-943). Outbound only: the sender address
  # receives no mail, and the mail says so. Written in the language of who answers.
  class RepliesMailer < ApplicationMailer
    def reply(message)
      @message = message
      @request = message.request
      return if @request.email.blank?

      @project = @request.project
      mail to: @request.email, subject: t("helpdesk.mailer.subject", project: @project.name)
    end

    private

    def recipient_locale(message) = message.author&.effective_locale || I18n.default_locale
  end
end
