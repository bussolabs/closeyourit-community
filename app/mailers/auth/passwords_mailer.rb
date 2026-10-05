# frozen_string_literal: true

module Auth
  class PasswordsMailer < ApplicationMailer
    def reset(account)
      @account = account
      @token = account.generate_token_for(:password_reset)
      mail to: account.email, subject: t("auth.passwords.mailer.subject")
    end
  end
end
