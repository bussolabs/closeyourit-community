# frozen_string_literal: true

module Helpdesk
  # Takes a request out of the inbox (spam, nothing to do). It stays readable among the discarded ones.
  class DiscardRequest < ApplicationService
    def initialize(request:, actor:)
      @request = request
      @actor = actor
    end

    def call
      @request.update!(status: :discarded, discarded_at: Time.current, discarded_by: @actor) unless @request.status_discarded?
      Result.ok(@request)
    end
  end
end
