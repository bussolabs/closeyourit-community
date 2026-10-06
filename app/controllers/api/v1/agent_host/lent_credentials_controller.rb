# frozen_string_literal: true

module Api
  module V1
    module AgentHost
      # Serves a secret the organization lends to its machines to a certified host (CYAU-224, CYAU-228).
      # Host token (cyi_ah_) only; the response is never cached.
      class LentCredentialsController < Api::BaseController
        include AutomatorAuthentication

        class_attribute :credential_name, instance_writer: false

        before_action :authenticate_automator_host!

        def show
          response.headers["Cache-Control"] = "no-store"
          result = ::Agents::Hosts::LentCredential.call(host: Current.agent_host, credential: credential_name)
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
