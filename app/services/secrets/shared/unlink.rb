# frozen_string_literal: true

module Secrets
  module Shared
    class Unlink < ApplicationService
      include ::Secrets::Github::Syncable

      def initialize(delegation:, actor: nil, confirmation_digest:)
        @delegation, @actor, @confirmation_digest = delegation, actor, confirmation_digest
      end

      def call
        value = @delegation.shared_value
        impact = Impact.call(shared_value: value, effect: :unlink).value
        return Result.err(AppError.new("Conferma obsoleta", code: "R409-SHARED-001", details: impact)) unless secure?(impact)
        project = @delegation.project
        ApplicationRecord.transaction do
          @delegation.destroy!
          Event.create!(organization: value.organization, shared_variable: value.shared_variable,
                        environment: value.environment, project:, actor: @actor, action: "unlinked", name: value.name)
        end
        enqueue_github_sync(project)
        Result.ok(project)
      end

      private

      def secure?(impact) = ActiveSupport::SecurityUtils.secure_compare(@confirmation_digest.to_s, impact["digest"])
    end
  end
end
