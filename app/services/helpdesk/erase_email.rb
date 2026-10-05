# frozen_string_literal: true

module Helpdesk
  # Removes the visitor's address from a request. The message stays; the way back to the person does not.
  class EraseEmail < ApplicationService
    def initialize(request:)
      @request = request
    end

    def call
      @request.update!(email: nil, email_erased_at: Time.current) if @request.email.present?
      Result.ok(@request)
    end
  end
end
