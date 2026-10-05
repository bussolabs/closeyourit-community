# frozen_string_literal: true

module Secrets
  module Variables
    # Update metadata without copying an old value over a concurrent rotation. CYRA-987
    class UpdateDescription < ApplicationService
      include Secrets::Github::Syncable

      def initialize(project:, environment:, name:, description:, actor:, enqueue_sync: true, audit: true)
        @project = project
        @environment = environment
        @name = name.to_s.strip.upcase
        @description = description
        @actor = actor
        @enqueue_sync = enqueue_sync
        @audit = audit
      end

      def call
        variable = @project.secret_variables.find_by(environment: @environment, name: @name)
        return missing_variable unless variable

        variable.with_lock { variable.update!(description: @description) }
        if @audit
          ::Secrets::RecordEvent.call(action: "set", project: @project, environment: @environment,
                                     actor: @actor, name: @name)
        end
        enqueue_github_sync(@project) if @enqueue_sync
        Result.ok(variable)
      rescue ActiveRecord::RecordNotFound
        missing_variable
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-SECRET-001", details: e.record.errors.to_hash))
      end

      private

      def missing_variable
        Result.err(AppError.new(I18n.t("member.review_completion.secret_missing"), code: "R409-SECRET-005",
                                status: :conflict))
      end
    end
  end
end
