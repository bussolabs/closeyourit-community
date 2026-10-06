# frozen_string_literal: true

module Agents
  # The OpenRouter key OpenCode reviews with on the organization's machines (CYAU-228).
  class OpenrouterCredential < ApplicationRecord
    include LentCredential

    # The variable the host gives OpenCode; OpenCode reads its OpenRouter key from it.
    ENV_NAME = "OPENROUTER_API_KEY"

    validates :token, presence: true, format: { with: /\Ask-or-[A-Za-z0-9_-]+\z/, allow_blank: true }

    def served = { env: ENV_NAME, token: token }

    # The token must never reach a log or a console.
    def inspect
      "#<#{self.class.name} id: #{id.inspect} organization_id: #{organization_id.inspect}>"
    end
  end
end
