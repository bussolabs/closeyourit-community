# frozen_string_literal: true

module Api
  module V1
    # Policy effettiva letta dall'Automator. La lettura accetta il token organization durante il
    # bootstrap; dopo la registrazione usa il token host dedicato.
    class LimitsController < Api::BaseController
      include AutomatorAuthentication

      before_action :authenticate_automator!

      def show
        runtime = params[:runtime].to_s.strip.downcase.presence
        return invalid_runtime if runtime && !::Agents::LimitPolicy::RUNTIMES.include?(runtime)

        project = resolve_project
        return if performed?

        render_ok(::Agents::Limits::Resolve.call(organization: Current.organization, project:, runtime:))
      end

      private

      def resolve_project
        repository = params[:repository].to_s.strip
        return nil if repository.blank?

        Current.organization.projects.joins(:github_repository)
               .find_by!(github_repositories: { full_name: repository })
      rescue ActiveRecord::RecordNotFound
        render_error("R404-AGENT-002", "Progetto non trovato", status: :not_found)
        nil
      end

      def invalid_runtime
        render_error("R422-AGENT-005", "Runtime non valido", status: :unprocessable_content)
      end
    end
  end
end
