# frozen_string_literal: true

module Authorization
  # Imposta i ruoli DIRETTI di un account in un'org (sostituisce l'insieme, idempotente), SOLO ruoli
  # dell'org (anti-BOLA). L'account dev'essere membro (validato sul model). Transazionale, audit sync.
  class SetAccountRoles < ApplicationService
    def initialize(organization:, account:, role_ids:, actor: nil, true_actor: nil)
      @organization = organization
      @account = account
      @role_ids = Array(role_ids).reject(&:blank?)
      @actor = actor
      @true_actor = true_actor
    end

    def call
      # Assegnare un ruolo = concedere TUTTE le sue chiavi. Chiavi concesse = union delle permission_key
      # dei ruoli AGGIUNTI. Guard anti-escalation PRIMA della transazione (fail-fast): un non-owner non
      # può assegnare un ruolo che porta chiavi che non possiede o chiavi scoped (concesse org-wide).
      keep = @organization.roles.where(id: @role_ids).ids
      current = @account.account_roles.where(organization_id: @organization.id).pluck(:role_id)
      add = keep - current
      granted = Authorization::RolePermission.where(role_id: add).distinct.pluck(:permission_key)
      barrier = grant_barrier(granted)
      return Result.err(barrier) if barrier

      ActiveRecord::Base.transaction do
        scope = @account.account_roles.where(organization_id: @organization.id)
        remove = current - keep
        scope.where(role_id: remove).destroy_all if remove.any?
        add.each { |rid| @account.account_roles.create!(organization_id: @organization.id, role_id: rid) }
        audit("account_role_added", add)
        audit("account_role_removed", remove)
      end
      Result.ok(@account)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: "R422-ACCESS-005", details: e.record.errors.to_hash))
    end

    private

    # AppError R403-ACCESS-001 se `keys` contiene chiavi che l'attore non può concedere, altrimenti nil.
    def grant_barrier(keys)
      forbidden = Authorization::GrantGuard.forbidden_keys(actor: @actor, organization: @organization, keys: keys)
      return if forbidden.empty?

      AppError.new("Non puoi concedere permessi o ruoli che non possiedi",
                   code: "R403-ACCESS-001", status: :forbidden, details: { forbidden_keys: forbidden })
    end

    def audit(action, ids)
      return if ids.empty?

      Authorization::RecordChange.call(
        organization: @organization, action: action,
        actor: @actor, true_actor: @true_actor,
        data: { account: @account.name, roles: @organization.roles.where(id: ids).pluck(:name) }
      )
    end
  end
end
