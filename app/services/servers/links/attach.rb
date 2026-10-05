# frozen_string_literal: true

module Servers
  module Links
    # Collega un host a un environment di un progetto. Idempotente: ri-collegare la stessa tripla
    # è un no-op (ritorna il link esistente). Gate uptime + subset environment + tenant host sono
    # applicati dal model (Connections::EnvironmentHost).
    class Attach < ApplicationService
      def initialize(project:, environment:, host:, actor: nil)
        @project = project
        @environment = environment
        @host = host
        @actor = actor
      end

      def call
        link = Connections::EnvironmentHost.find_or_initialize_by(
          project: @project, environment: @environment, host: @host
        )
        return Result.ok(link) if link.persisted?

        link.created_by = @actor
        return Result.ok(link) if link.save

        Result.err(AppError.new(link.errors.full_messages.to_sentence,
                                code: "R422-SERVER-006", status: :unprocessable_content))
      end
    end
  end
end
