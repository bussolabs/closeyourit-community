# frozen_string_literal: true

module Helpdesk
  # Brings a discarded request back to the inbox.
  class RestoreRequest < ApplicationService
    def initialize(request:)
      @request = request
    end

    def call
      @request.update!(status: :received, discarded_at: nil, discarded_by: nil) if @request.status_discarded?
      Result.ok(@request)
    end
  end
end
