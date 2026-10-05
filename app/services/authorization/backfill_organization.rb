# frozen_string_literal: true

module Authorization
  # Backfill one-shot (idempotente, ADDITIVO) per preservare il comportamento attuale al passaggio
  # al nuovo regime "solo owner vede tutto": installa i ruoli default e, se l'org ha admin, crea il
  # team "Administrators" (ruolo Administrator) collegato a TUTTI i progetti/gruppi attuali e ci mette
  # gli account oggi `admin`. Additivo: non rimuove mai link/membri (preserva eventuali edit dell'owner).
  # Gli ex-admin mantengono così la visibilità sui progetti ESISTENTI; i FUTURI vanno assegnati a mano.
  class BackfillOrganization < ApplicationService
    def initialize(organization:)
      @organization = organization
    end

    def call
      Authorization::InstallDefaultRoles.call(organization: @organization)

      admin_account_ids = @organization.memberships.where(role: :admin).pluck(:account_id)
      return Result.ok(nil) if admin_account_ids.empty?

      ActiveRecord::Base.transaction do
        team = @organization.teams.find_or_create_by!(name: "Administrators")
        ensure_admin_role(team)
        link_all_scope(team)
        add_admins(team, admin_account_ids)
        Result.ok(team)
      end
    end

    private

    def ensure_admin_role(team)
      role = @organization.roles.find_by!(name: "Administrator")
      team.team_roles.create!(role: role) unless team.team_roles.exists?(role_id: role.id)
    end

    def link_all_scope(team)
      existing_projects = team.project_accesses.pluck(:project_id)
      (@organization.projects.ids - existing_projects).each { |pid| team.project_accesses.create!(project_id: pid) }

      existing_groups = team.group_accesses.pluck(:group_id)
      (@organization.groups.ids - existing_groups).each { |gid| team.group_accesses.create!(group_id: gid) }
    end

    def add_admins(team, admin_account_ids)
      existing = team.team_memberships.pluck(:account_id)
      (admin_account_ids - existing).each { |aid| team.team_memberships.create!(account_id: aid) }
    end
  end
end
