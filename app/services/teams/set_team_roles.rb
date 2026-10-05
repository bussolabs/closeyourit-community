# frozen_string_literal: true

module Teams
  # Imposta i ruoli di un team (sostituisce l'insieme, idempotente), SOLO ruoli dell'org del team
  # (anti-BOLA). Transazionale, audit sync. Result pattern.
  class SetTeamRoles < ApplicationService
    def initialize(team:, role_ids:, actor: nil, true_actor: nil)
      @team = team
      @organization = team.organization
      @role_ids = Array(role_ids).reject(&:blank?)
      @actor = actor
      @true_actor = true_actor
    end

    def call
      # Assegnare un ruolo al team = concedere TUTTE le sue chiavi ai membri. Chiavi concesse = union delle
      # permission_key dei ruoli AGGIUNTI. Guard anti-escalation PRIMA della transazione (fail-fast): un
      # non-owner non può dare al team un ruolo con chiavi che non possiede o chiavi scoped (org-wide).
      keep = @organization.roles.where(id: @role_ids).ids
      current = @team.team_roles.pluck(:role_id)
      add = keep - current
      granted = Authorization::RolePermission.where(role_id: add).distinct.pluck(:permission_key)
      barrier = grant_barrier(granted)
      return Result.err(barrier) if barrier

      ActiveRecord::Base.transaction do
        remove = current - keep
        @team.team_roles.where(role_id: remove).destroy_all if remove.any?
        add.each { |rid| @team.team_roles.create!(role_id: rid) }
        audit("team_role_added", add)
        audit("team_role_removed", remove)
      end
      Result.ok(@team)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: "R422-ACCESS-003", details: e.record.errors.to_hash))
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
        data: { team: @team.name, roles: @organization.roles.where(id: ids).pluck(:name) }
      )
    end
  end
end
