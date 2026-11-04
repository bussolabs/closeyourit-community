# frozen_string_literal: true

module Projects
  module Releases
    # Restores a retired release: the invitation to update disappears (CYRA-1161).
    class Restore < ApplicationService
      def initialize(release:, actor:, true_actor: nil)
        @release = release
        @actor = actor
        @true_actor = true_actor
      end

      def call
        ApplicationRecord.transaction do
          @release.update!(retired_at: nil, retirement_message: nil, retired_by: nil)
          Activity::Record.call(subject: @release.project, action: "updated", actor: @actor, true_actor: @true_actor,
                                data: { fields: [ "release_restored" ], version: @release.version })
        end
        Status.expire(@release)
        Result.ok(@release)
      end
    end
  end
end
