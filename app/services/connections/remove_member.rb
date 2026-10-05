# frozen_string_literal: true

module Connections
  # Rimuove un membro dall'organizzazione revocando TUTTO l'accesso residuo (chiavi CLI, scope, ruoli,
  # override, team, preferenze avvisi) via Connections::RevokeOrgAccess — non basta togliere la riga
  # (CYRA-241). Vieta di rimuovere l'ultimo owner.
  class RemoveMember < ApplicationService
    def initialize(membership:)
      @membership = membership
    end

    def call
      return err("R422-MEMBER-004", :last_owner) if last_owner?

      Connections::RevokeOrgAccess.call(account: @membership.account, organization: @membership.organization)
    end

    private

    def last_owner?
      return false unless @membership.owner?

      @membership.organization.memberships.owner.where.not(id: @membership.id).none?
    end

    def err(code, key)
      Result.err(AppError.new(I18n.t("member.errors.#{key}"), code: code))
    end
  end
end
