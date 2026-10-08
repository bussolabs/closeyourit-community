# frozen_string_literal: true

module Agents
  module ClaudeCredentials
    # CYRA-1052 — the vault secrets an owner can link as a Claude credential: the organization's shared ones
    # (one per environment) and the owner's own personal ones. Names only: values never leave the vault here.
    class SecretOptions
      def self.call(organization:, account:)
        shared = Secrets::Shared::Value.joins(:shared_variable, :environment)
                                       .where(secrets_shared_variables: { organization_id: organization.id })
                                       .order("secrets_shared_variables.name", "types_environments.position")
                                       .pluck(:id, "secrets_shared_variables.name", "types_environments.label")
        personal = Secrets::Personal::Variable.for(account:, organization:).ordered.pluck(:id, :name)

        shared.map { |id, name, env| [ I18n.t("member.claude_credential.secret_shared", name:, env:), "shared:#{id}" ] } +
          personal.map { |id, name| [ I18n.t("member.claude_credential.secret_personal", name:), "personal:#{id}" ] }
      end
    end
  end
end
