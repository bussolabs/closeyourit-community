# frozen_string_literal: true

module Github
  module Installations
    # Registra (o aggiorna) l'installazione della GitHub App per un'organizzazione dopo il callback di
    # installazione su GitHub. Idempotente: 1 installazione per org (find_or_initialize su organization).
    class Connect < ApplicationService
      def initialize(organization:, installation_id:, code:, redirect_uri:)
        @organization = organization
        @installation_id = installation_id
        @code = code
        @redirect_uri = redirect_uri
      end

      def call
        verification = Verify.call(installation_id: @installation_id, code: @code, redirect_uri: @redirect_uri)
        return verification if verification.err?

        installation = ::Github::Installation.find_or_initialize_by(organization: @organization)
        installation.installation_id = @installation_id
        installation.account_login = verification.value.fetch("account").fetch("login")

        return Result.ok(installation) if installation.save

        Result.err(AppError.new(installation.errors.full_messages.to_sentence,
                                code: "R422-GITHUB-001", details: installation.errors.to_hash))
      end
    end
  end
end
