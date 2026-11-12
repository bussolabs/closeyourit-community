# frozen_string_literal: true

module Projects
  module TestAccess
    # CYRA-1303 — the password of the project's test account goes in the project's vault, staging environment:
    # encrypted, versioned and audited like every other secret, and already reachable by the machines that
    # run a proof on staging. The page never reads it back: `set?` only says whether it is there.
    class SavePassword < ApplicationService
      NAME = "TEST_ACCESS_PASSWORD"
      ENVIRONMENT = "staging"
      DESCRIPTION = "Password of the test account used to try the work on staging"

      def self.environment(project) = project.environments.find_by(code: ENVIRONMENT)

      def self.set?(project)
        environment = environment(project)
        environment.present? && project.secret_variables.exists?(environment:, name: NAME)
      end

      def initialize(project:, password:, actor:)
        @project = project
        @password = password.to_s
        @actor = actor
      end

      def call
        environment = self.class.environment(@project)
        return Result.err(AppError.new("The project has no staging environment", code: "R422-TEST-ACCESS-001")) if environment.nil?

        Secrets::Variables::Set.call(project: @project, environment:, name: NAME, value: @password,
                                     description: DESCRIPTION, actor: @actor)
      end
    end
  end
end
