# frozen_string_literal: true

module Helpdesk
  # Erases the visitors' addresses older than the retention (CYRA-940). The message stays: only the
  # way back to the person goes.
  class EraseExpiredEmailsJob < ApplicationJob
    queue_as :batch

    def perform
      Helpdesk::Request.where.not(email: nil)
                       .where(created_at: ..Helpdesk::Constants::EMAIL_RETENTION.ago)
                       .in_batches.update_all(email: nil, email_erased_at: Time.current)
    end
  end
end
