# frozen_string_literal: true

require "digest"

module Secrets
  module Shared
    class Impact < ApplicationService
      def initialize(shared_value:, effect:)
        @shared_value = shared_value
        @effect = effect.to_s
      end

      def call
        projects = @shared_value.projects.includes(:github_repository).order(:name).map do |project|
          repository = project.github_repository
          {
            "id" => project.id,
            "name" => project.name,
            "environment" => @shared_value.environment.code,
            "repository" => repository&.sync_secrets? ? repository.full_name : nil
          }
        end
        payload = { "effect" => @effect, "name" => @shared_value.name, "projects" => projects }
        Result.ok(payload.merge("digest" => Digest::SHA256.hexdigest(payload.to_json)))
      end
    end
  end
end
