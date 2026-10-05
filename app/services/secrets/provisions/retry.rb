# frozen_string_literal: true

module Secrets
  module Provisions
    class Retry < ApplicationService
      def initialize(provision:, actor:)
        @provision = provision
        @actor = actor
      end

      def call
        return forbidden_environment unless environments_allowed?
        return Result.ok(@provision) if @provision.ready?
        return Result.err(AppError.new(I18n.t("provisions.errors.github_required"),
                                       code: "R422-PROVISION-004")) unless github_ready?

        @provision.update!(status: :pending_sync, error_code: nil, error_message: nil)
        Secrets::Provisions::SyncJob.perform_later(provision_id: @provision.id)
        Result.ok(@provision)
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(I18n.t("provisions.errors.invalid"), code: "R422-PROVISION-002",
                                details: e.record.errors.as_json))
      end

      private

      def environments_allowed?
        return false if @actor.nil?

        source = ::Secrets::EnvironmentAccess.new(account: @actor, project: @provision.source_project)
        destination = ::Secrets::EnvironmentAccess.new(account: @actor, project: @provision.destination_project)
        source.allowed?(@provision.source_environment.code) && !destination.restricted?
      end

      def forbidden_environment
        Rails.logger.warn("Token provision retry environment denied actor_id=#{@actor&.id} provision_id=#{@provision.id}")
        Result.err(AppError.new("This account cannot synchronize credentials in these environments",
                                code: "R403-PROVISION-001", status: :forbidden))
      end

      def github_ready?
        repository = @provision.destination_project.github_repository
        mapped_ids = [ repository&.production_environment_id, repository&.staging_environment_id ].compact
        @provision.sync_github? && repository&.sync_secrets? &&
          mapped_ids.include?(@provision.destination_environment_id)
      end
    end
  end
end
