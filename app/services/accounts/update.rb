# frozen_string_literal: true

module Accounts
  # Organization membership editors can update display fields, never the global recovery identity.
  class Update < ApplicationService
    def initialize(account:, attributes:)
      @account = account
      @attributes = attributes.to_h.symbolize_keys
    end

    def call
      if @attributes.key?(:email) && @attributes[:email].to_s.strip.downcase != @account.email
        Rails.logger.warn("Member email change denied account_id=#{@account.id}")
        message = "The account email cannot be changed through organization membership management"
        return Result.err(AppError.new(message, code: "R422-ACCOUNT-001", details: { email: [ message ] }))
      end

      if @account.update(@attributes.slice(:name, :handle))
        Result.ok(@account)
      else
        Result.err(AppError.new(
                     @account.errors.full_messages.to_sentence,
                     code: "R422-ACCOUNT-001",
                     details: @account.errors.to_hash
                   ))
      end
    end
  end
end
