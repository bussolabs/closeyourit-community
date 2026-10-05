# frozen_string_literal: true

module Uptime
  module Announcements
    # Crea/aggiorna l'unico banner del monitor (manutenzioni/avvisi sulla status page pubblica).
    class Save < ApplicationService
      def initialize(monitor:, attributes:, actor: nil)
        @monitor = monitor
        @attributes = attributes
        @actor = actor
      end

      def call
        announcement = @monitor.announcement || @monitor.build_announcement
        announcement.assign_attributes(@attributes)
        announcement.created_by ||= @actor

        if announcement.save
          Result.ok(announcement)
        else
          Result.err(AppError.new(announcement.errors.full_messages.to_sentence,
                                  code: "R422-UPTIME-003", status: :unprocessable_content,
                                  details: announcement.errors.to_hash))
        end
      end
    end
  end
end
