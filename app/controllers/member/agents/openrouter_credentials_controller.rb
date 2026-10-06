# frozen_string_literal: true

module Member
  module Agents
    # The OpenRouter key the organization lends to its machines for OpenCode reviews (CYAU-228).
    class OpenrouterCredentialsController < LentCredentialsController
      self.credential_name = :openrouter_credential
    end
  end
end
