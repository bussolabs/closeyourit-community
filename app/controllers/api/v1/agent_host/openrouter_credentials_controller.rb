# frozen_string_literal: true

module Api
  module V1
    module AgentHost
      # Serves the organization's OpenRouter key (CYAU-228) to a certified host.
      class OpenrouterCredentialsController < LentCredentialsController
        self.credential_name = :openrouter_credential
      end
    end
  end
end
