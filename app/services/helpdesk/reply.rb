# frozen_string_literal: true

module Helpdesk
  # A person of the team answers the visitor (CYRA-943): the answer is saved in the request and
  # leaves by email. Only ever a written answer, never an automatic one, and with a cap: the address
  # was typed by a stranger.
  class Reply < ApplicationService
    def initialize(request:, author:, body:)
      @request = request
      @author = author
      @body = body
    end

    def call
      return err("R422-HELPDESK-004", :no_email) if @request.email.blank?
      return err("R422-HELPDESK-002", :already_handled) if @request.status_discarded?
      return err("R422-HELPDESK-005", :too_many_replies) if replies_count >= Helpdesk::Constants::REPLIES_PER_REQUEST_MAX

      message = @request.messages.new(direction: :outbound, author: @author, body: @body)
      return invalid(message) unless message.valid?

      ApplicationRecord.transaction do
        message.save!
        @request.update!(status: :answered) if @request.status_received?
      end
      # Outside the transaction: the mail job must find the message committed.
      Helpdesk::RepliesMailer.reply(message).deliver_later
      Result.ok(message)
    end

    private

    def replies_count = @request.messages.where(direction: :outbound).count

    def err(code, key) = Result.err(AppError.new(I18n.t("member.helpdesk.errors.#{key}"), code: code))

    def invalid(message)
      Result.err(AppError.new(message.errors.full_messages.to_sentence, code: "R422-HELPDESK-001",
                                                                        details: message.errors.to_hash))
    end
  end
end
