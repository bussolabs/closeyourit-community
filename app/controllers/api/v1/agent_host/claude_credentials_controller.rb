# frozen_string_literal: true

module Api
  module V1
    module AgentHost
      # Serves the organization's Claude credential (CYAU-224) to a certified host.
      class ClaudeCredentialsController < LentCredentialsController
        self.credential_name = :claude_credential
      end
    end
  end
end
