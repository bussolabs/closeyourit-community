# frozen_string_literal: true

module Api
  module V1
    module AgentHost
      # Serves a GitHub token for the repository of the ticket the host holds (CYRA-1058). Never cached.
      class GithubTokensController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!

        def create
          response.headers["Cache-Control"] = "no-store"
          result = ::Agents::Hosts::GithubToken.call(host: Current.agent_host, ticket_reference: params[:ticket])
          if result.ok?
            render_ok(result.value)
          else
            render_error(result.error.code, result.error.message, status: result.error.status)
          end
        end
      end
    end
  end
end
