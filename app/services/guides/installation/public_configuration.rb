# frozen_string_literal: true

module Guides
  module Installation
    class PublicConfiguration < ApplicationService
      def initialize(project:, actor:, organization:, observation:, host:, environment: nil)
        @project, @actor, @organization, @observation, @host, @environment = project, actor, organization, observation, host, environment
      end

      def call
        return nil unless @project && public_configuration?
        return nil unless Authorization::VisibleScope.new(account: @actor, organization: @organization).projects.exists?(id: @project.id)
        return nil unless Authorization::Resolver.new(account: @actor, organization: @organization).can?("tokens.manage", scope: @project)
        tokens = @project.tokens.active.where("scopes @> ?::jsonb", JSON.generate([ "ingest" ]))
        tokens = tokens.joins(:environment).where(types_environments: { code: @environment }) if @environment.present?
        token = tokens.select(:id, :project_id, :environment_id, :public_key, :created_at).order(:created_at, :id).first
        return nil unless token
        { public_key: token.public_key, sentry_dsn: token.to_sentry_dsn(host: @host), environment: token.environment.code }
      end

      private

      def public_configuration?
        @observation.dig("tuple", "auth_mode") == "public_dsn" || @observation.dig("tuple", "integration").start_with?("php-laravel")
      end
    end
  end
end
