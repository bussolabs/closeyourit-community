# frozen_string_literal: true

module Projects
  module Tokens
    # Genera una credenziale e la deposita direttamente nel vault cifrato di un progetto visibile.
    # Il plaintext resta confinato a questo stack frame e non entra mai nel Result o nei job.
    class Provision < ApplicationService
      VALID_SCOPES = %w[ingest read].freeze

      class Abort < StandardError
        attr_reader :error

        def initialize(error)
          @error = error
          super(error.code)
        end
      end

      def initialize(source_project:, source_environment:, destination_project:, destination_environment:,
                     name:, secret_name:, idempotency_key:, created_by: nil, scopes: [ "ingest" ],
                     sync_github: true, host: App::Host.primary)
        @source_project = source_project
        @source_environment = source_environment
        @destination_project = destination_project
        @destination_environment = destination_environment
        @name = name.to_s.strip
        @secret_name = secret_name.to_s.strip.upcase
        @idempotency_key = idempotency_key.to_s.strip
        @created_by = created_by
        @scopes = Array(scopes).map(&:to_s).reject(&:blank?).uniq.sort
        @sync_github = sync_github
        @host = host
      end

      def call
        return error("R422-PROVISION-001", :idempotency_required) if @idempotency_key.blank?
        return forbidden_environment unless environments_allowed?

        existing = organization.secret_provisions.find_by(idempotency_key: @idempotency_key)
        return replay(existing) if existing

        guard = validate_request
        return guard if guard

        provision = create_provision!
        enqueue_sync(provision) if provision.sync_github?
        Result.ok(provision)
      rescue Abort => e
        Result.err(e.error)
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(I18n.t("provisions.errors.invalid"), code: "R422-PROVISION-002",
                                details: e.record.errors.as_json))
      rescue ActiveRecord::RecordNotUnique
        concurrent = organization.secret_provisions.find_by(idempotency_key: @idempotency_key)
        raise unless concurrent

        replay(concurrent)
      end

      private

      def environments_allowed?
        return false if @created_by.nil?

        accesses = ::Secrets::EnvironmentAccess.for_projects(
          account: @created_by, projects: [ @source_project, @destination_project ])
        source_access = accesses.fetch(@source_project.id)
        destination_access = accesses.fetch(@destination_project.id)
        return false if @sync_github && destination_access.restricted?

        source_access.allowed?(@source_environment.code) && destination_access.allowed?(@destination_environment.code)
      end

      def forbidden_environment
        Rails.logger.warn("Token provision environment denied actor_id=#{@created_by&.id}")
        Result.err(AppError.new("This account cannot provision credentials in this environment",
                                code: "R403-PROVISION-001", status: :forbidden))
      end

      def create_provision!
        provision = nil
        ApplicationRecord.transaction do
          issued = ::Projects::Tokens::Issue.call(
            project: @source_project, environment: @source_environment, name: @name,
            host: @host, created_by: @created_by, scopes: @scopes
          )
          raise Abort, issued.error if issued.err?

          stored = ::Secrets::Variables::Set.call(
            project: @destination_project, environment: @destination_environment,
            name: @secret_name, value: issued.value.fetch(:secret), actor: @created_by,
            enqueue_sync: false
          )
          raise Abort, stored.error if stored.err?

          provision = organization.secret_provisions.create!(
            source_project: @source_project, source_environment: @source_environment,
            destination_project: @destination_project, destination_environment: @destination_environment,
            token: issued.value.fetch(:token), secret_variable: stored.value, created_by: @created_by,
            secret_name: @secret_name, idempotency_key: @idempotency_key,
            request_fingerprint: request_fingerprint, sync_github: @sync_github,
            status: @sync_github ? :pending_sync : :ready
          )
        end
        provision
      end

      def validate_request
        return error("R422-PROVISION-002", :invalid) unless same_organization?
        return error("R422-PROVISION-002", :invalid_environment) unless environments_declared?
        return error("R422-PROVISION-005", :invalid_scopes) unless valid_scopes?
        return error("R422-PROVISION-004", :github_required) if @sync_github && !github_ready?

        nil
      end

      def same_organization?
        @destination_project.organization_id == organization.id &&
          @source_environment.organization_id == organization.id &&
          @destination_environment.organization_id == organization.id
      end

      def environments_declared?
        @source_project.environment_ids.include?(@source_environment.id) &&
          @destination_project.environment_ids.include?(@destination_environment.id)
      end

      def valid_scopes? = @scopes.present? && (@scopes - VALID_SCOPES).empty?

      def github_ready?
        repository = @destination_project.github_repository
        repository&.sync_secrets? && repository_maps_destination?(repository)
      end

      def repository_maps_destination?(repository)
        [ repository.production_environment_id, repository.staging_environment_id ]
          .compact.include?(@destination_environment.id)
      end

      def replay(existing)
        return Result.ok(existing) if existing.request_fingerprint == request_fingerprint

        error("R409-PROVISION-001", :idempotency_conflict, status: :conflict)
      end

      def request_fingerprint
        @request_fingerprint ||= Digest::SHA256.hexdigest(
          {
            source_project_id: @source_project.id,
            source_environment_id: @source_environment.id,
            destination_project_id: @destination_project.id,
            destination_environment_id: @destination_environment.id,
            name: @name,
            secret_name: @secret_name,
            scopes: @scopes,
            sync_github: @sync_github
          }.to_json
        )
      end

      def organization = @source_project.organization

      def enqueue_sync(provision)
        ::Secrets::Provisions::SyncJob.perform_later(provision_id: provision.id)
      rescue StandardError => e
        Rails.logger.error("Secret provision enqueue failed: #{e.class}")
        provision.update!(status: :failed, error_code: "R503-PROVISION-001",
                          error_message: I18n.t("provisions.errors.sync_failed"))
      end

      def error(code, key, status: :unprocessable_content)
        Result.err(AppError.new(I18n.t("provisions.errors.#{key}"), code:, status:))
      end
    end
  end
end
