# frozen_string_literal: true

module Projects
  module Releases
    # Retires a release: its users are invited to update, with the message (CYRA-1161).
    # The gesture lands in the project history and drops the ready answer of Status.
    class Retire < ApplicationService
      def initialize(release:, message:, actor:, true_actor: nil)
        @release = release
        @message = message
        @actor = actor
        @true_actor = true_actor
      end

      def call
        ApplicationRecord.transaction do
          @release.update!(retired_at: Time.current, retirement_message: @message, retired_by: @actor)
          Activity::Record.call(subject: @release.project, action: "updated", actor: @actor, true_actor: @true_actor,
                                data: { fields: [ "release_retired" ], version: @release.version })
        end
        Status.expire(@release)
        Result.ok(@release)
      rescue ActiveRecord::RecordInvalid
        @release.restore_attributes
        Result.err(AppError.new(I18n.t("member.projects.release_retirement.message_required"),
                                code: "R422-RELEASE-003", status: :unprocessable_content))
      end
    end
  end
end
