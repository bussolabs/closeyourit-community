# frozen_string_literal: true

module Support
  # Announces a new support request (CYRA-935) to the support address, or to the god accounts when
  # none is set. Written in the default language: the reader is whoever runs the install.
  class RequestsMailer < ApplicationMailer
    def created(support_request)
      @support_request = support_request
      @account = support_request.account
      recipients = self.class.recipients
      return if recipients.empty?

      mail to: recipients, reply_to: @account.email,
           subject: t("support.mailer.subject", name: @account.name.presence || @account.email)
    end

    def self.recipients
      configured = ENV[Constants::RECIPIENT_ENV].to_s.split(",").map(&:strip).compact_blank
      configured.presence || Accounts::Account.where(god: true).pluck(:email)
    end

    private

    def recipient_locale(_arg) = I18n.default_locale
  end
end
