# frozen_string_literal: true

module Teams
  # Imposta i membri di un team (sostituisce l'insieme, idempotente), SOLO account membri dell'org
  # (anti-BOLA). Transazionale, audit sync. Result pattern.
  class SetTeamMembers < ApplicationService
    def initialize(team:, account_ids:, actor: nil, true_actor: nil)
      @team = team
      @organization = team.organization
      @account_ids = Array(account_ids).reject(&:blank?)
      @actor = actor
      @true_actor = true_actor
    end

    def call
      keep = @organization.accounts.where(id: @account_ids).ids
      current = @team.team_memberships.pluck(:account_id)
      add = keep - current
      barrier = addition_barrier if add.any?
      return Result.err(barrier) if barrier

      ActiveRecord::Base.transaction do
        remove = current - keep
        @team.team_memberships.where(account_id: remove).destroy_all if remove.any?
        add.each { |aid| @team.team_memberships.create!(account_id: aid) }
        audit("team_member_added", add)
        audit("team_member_removed", remove)
      end
      Result.ok(@team)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: "R422-ACCESS-007", details: e.record.errors.to_hash))
    end

    private

    # Joining a team grants its existing roles and scope, even when neither is being edited.
    def addition_barrier
      keys = Authorization::RolePermission.where(role_id: @team.team_roles.select(:role_id)).distinct.pluck(:permission_key)
      forbidden = Authorization::GrantGuard.forbidden_keys(actor: @actor, organization: @organization, keys:)
      if forbidden.any?
        return AppError.new("You cannot grant this team's permissions", code: "R403-ACCESS-001",
                            status: :forbidden, details: { forbidden_keys: forbidden })
      end

      Authorization::ScopeGuard.plan(
        actor: @actor, organization: @organization,
        project_ids: @team.project_accesses.pluck(:project_id), current_project_ids: [],
        group_ids: @team.group_accesses.pluck(:group_id), current_group_ids: []
      ).barrier
    end

    def audit(action, ids)
      return if ids.empty?

      Authorization::RecordChange.call(
        organization: @organization, action: action,
        actor: @actor, true_actor: @true_actor,
        data: { team: @team.name, members: Accounts::Account.where(id: ids).pluck(:name) }
      )
    end
  end
end
