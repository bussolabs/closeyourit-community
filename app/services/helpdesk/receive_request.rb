# frozen_string_literal: true

module Helpdesk
  # Stores what a visitor wrote from a project's site (CYRA-940). The address and the browser string
  # stop here: only the browser family reaches the table. No email is ever sent back from this step:
  # the address is typed by a stranger, so an automatic reply would mail whoever they name.
  class ReceiveRequest < ApplicationService
    def initialize(project:, message:, email: nil, page_url: nil, session_id: nil, user_agent: nil)
      @project = project
      @message = message.to_s
      @email = email.to_s.strip.presence
      @page_url = page_url.to_s.strip.presence
      @session_id = session_id.to_s.strip.presence
      @user_agent = user_agent
    end

    def call
      request = @project.helpdesk_requests.new(request_attributes)
      message = request.messages.new(direction: :inbound, body: @message)
      request.summary = message.body.to_s.squish.truncate(Helpdesk::Constants::SUMMARY_MAX_CHARS)
      return invalid(request, message) unless message.valid? && request.valid?

      request.save!
      # Without AI nothing is queued: the requests are simply not grouped. CYRA-943
      Helpdesk::EmbedRequestJob.perform_later(request_id: request.id) if Ai::Configuration.current.embeddings_configured?
      Result.ok(request)
    end

    private

    def request_attributes
      device = Analytics::Device.parse(@user_agent)
      { email: @email, page_url: @page_url, session_id: @session_id,
        browser: device.browser, os: device.os, device_type: device.device_type }
    end

    def invalid(request, message)
      details = message.errors.to_hash.merge(request.errors.to_hash.except(:messages, :summary))
      Result.err(AppError.new("Help desk request not valid", code: "R422-HELPDESK-001",
                                                             status: :unprocessable_content, details: details))
    end
  end
end
