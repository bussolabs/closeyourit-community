# frozen_string_literal: true

module Member
  module Agents
    # The Claude credential the organization lends to its automator machines (CYAU-224).
    class ClaudeCredentialsController < LentCredentialsController
      self.credential_name = :claude_credential
    end
  end
end
