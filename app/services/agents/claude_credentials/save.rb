# frozen_string_literal: true

module Agents
  module ClaudeCredentials
    # CYRA-1052 — saves the organization's Claude credential, or one machine's (`host:`), either pasted
    # (`token:`) or linked from a vault secret (`secret:` "personal:<id>" or "shared:<id>"). A pasted token
    # wins over a selected secret. A personal secret can only be the actor's own: whoever links it lends it.
    class Save < ApplicationService
      def initialize(organization:, actor:, host: nil, token: nil, secret: nil)
        @organization = organization
        @actor = actor
        @host = host
        @token = token.to_s.strip
        @secret = secret.to_s
      end

      def call
        credential = existing || Agents::ClaudeCredential.new(organization: @organization, host: @host)
        credential.assign_attributes(set_by: @actor, token: nil, personal_variable: nil, shared_value: nil)
        if @token.present?
          credential.token = @token
        else
          return invalid unless link(credential)
        end
        credential.save ? Result.ok(credential) : invalid
      end

      private

      def existing = @host ? @host.claude_credential : @organization.claude_credential

      def link(credential)
        kind, id = @secret.split(":", 2)
        case kind
        when "personal"
          credential.personal_variable = Secrets::Personal::Variable.for(account: @actor, organization: @organization).find_by(id:)
        when "shared"
          credential.shared_value = Secrets::Shared::Value.joins(:shared_variable)
                                                          .find_by(id:, secrets_shared_variables: { organization_id: @organization.id })
        end
        credential.personal_variable || credential.shared_value
      end

      def invalid
        Result.err(AppError.new(I18n.t("member.claude_credential.update.invalid"), code: "R422-AGENT-009"))
      end
    end
  end
end
