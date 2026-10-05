# frozen_string_literal: true

module Secrets
  module Provisions
    class SyncJob < ApplicationJob
      queue_as :ingest

      def perform(provision_id:)
        provision = Secrets::Provision.find_by(id: provision_id)
        return if provision.nil? || provision.ready?

        repository = provision.destination_project.github_repository
        unless repository&.sync_secrets? && mapped?(repository, provision)
          return fail_provision(provision, "R422-PROVISION-004")
        end

        result = Secrets::Github::Sync.call(repository:)

        if result.ok?
          provision.update!(status: :ready, synced_at: Time.current, error_code: nil, error_message: nil)
        else
          fail_provision(provision, result.error.code)
        end
      rescue StandardError => e
        Rails.logger.error("Secret provision sync failed: #{e.class}")
        fail_provision(provision, "R503-PROVISION-002") if provision&.persisted?
      end

      private

      def mapped?(repository, provision)
        [ repository.production_environment_id, repository.staging_environment_id ]
          .compact.include?(provision.destination_environment_id)
      end

      def fail_provision(provision, code)
        provision.update!(status: :failed, error_code: code,
                          error_message: I18n.t("provisions.errors.sync_failed"))
      end
    end
  end
end
