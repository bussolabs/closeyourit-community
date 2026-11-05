# frozen_string_literal: true

module Ticketing
  # Hourly round of the stalled-epic notice (CYRA-1155): finds epics whose children all wait for
  # someone and tells who has to act. A notice already sent for the same situation is not repeated.
  class NotifyStalledEpicsJob < ApplicationJob
    queue_as :maintenance

    def perform
      sent = Ticketing::StalledEpics::Detect.call.value.sum { |stall| Ticketing::StalledEpics::Notify.call(stall:).value }
      Rails.logger.info("Ticketing::NotifyStalledEpicsJob: #{sent} stalled-epic notices sent") if sent.positive?
      sent
    end
  end
end
