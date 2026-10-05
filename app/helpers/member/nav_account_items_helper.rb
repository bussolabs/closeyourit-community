# frozen_string_literal: true

module Member
  # The ORGANIZATION section (was "Account" until CYRA-903): the vault, by level (yours, the
  # organization's, a project's), and the organization's administration (CYRA-742).
  module NavAccountItemsHelper
    private

    # Secrets by LEVEL, then what needs doing (CYRA-428): variables and files of one level share an
    # entry, anomalies, rotations and requests share one list.
    def vault_items
      cp = controller.controller_path
      on_personal = cp.start_with?("member/personal_secret")
      on_organization = cp.start_with?("member/shared_secret")
      on_projects = cp.in?(%w[member/vault_projects member/project_secrets member/project_secret_assets
                              member/project_secret_versions member/vault/variable_search])

      # The whole area disappears for an external customer: `vault_nav_visible?` gates every entry (CYRA-586).
      [
        { label: "member.nav.overview", path: member_vault_path, icon: "compass",
          test: "member-nav-vault-overview", visible: vault_nav_visible?, overview: true,
          active: cp == "member/vault" },
        { label: "member.nav.vault_personal", path: member_personal_secrets_path, icon: "user-lock",
          test: "member-nav-vault-personal", visible: vault_nav_visible?, active: on_personal },
        # Two distinct permissions: whoever holds only the files one enters from the files tab.
        { label: "member.nav.vault_organization", path: organization_vault_path, icon: "building-2",
          test: "member-nav-vault-organization",
          visible: vault_nav_visible? && (can?("shared_secrets.manage") || can?("shared_secret_files.manage")),
          active: on_organization },
        { label: "member.nav.vault_project_secrets", path: member_vault_projects_path, icon: "folder",
          test: "member-nav-vault-projects", visible: vault_nav_visible?, active: on_projects },
        { label: "member.nav.vault_attention", path: member_vault_attention_path,
          icon: "triangle-alert", test: "member-nav-vault-attention",
          visible: vault_nav_visible? && (can?("secrets_audit.view") || vault_change_requests_nav_visible?),
          active: cp == "member/vault/attention" },
        { label: "member.nav.vault_audit", path: member_vault_audit_path, icon: "history",
          test: "member-nav-vault-audit", visible: vault_nav_visible? && can?("secrets_audit.view"),
          active: cp == "member/vault/audit" }
      ]
    end

    # Variables when they can be managed, otherwise files: the only tab left open to that permission.
    def organization_vault_path
      can?("shared_secrets.manage") ? member_shared_secrets_path : member_shared_secret_assets_path
    end

    def settings_items
      cp = controller.controller_path

      [
        { label: "member.nav.members", path: member_members_path, icon: "users",
          test: "member-nav-members", visible: can_view_members?,
          active: cp.in?(%w[member/members member/invitations]) },
        { label: "member.nav.service_accounts", path: member_service_accounts_path, icon: "bot",
          test: "member-nav-service-accounts", visible: can?("members.manage"),
          active: cp.start_with?("member/service/accounts") },
        { label: "member.nav.teams", path: member_teams_path, icon: "users",
          test: "member-nav-teams", visible: can_manage_permissions?, active: cp == "member/teams" },
        { label: "member.nav.roles", path: member_roles_path, icon: "shield-half",
          test: "member-nav-roles", visible: can_manage_permissions?, active: cp == "member/roles" },
        { label: "member.nav.platforms", path: member_platforms_path, icon: "shapes",
          test: "member-nav-platforms", visible: can_view_platforms?, active: cp == "member/platforms" },
        { label: "member.nav.environments", path: member_environments_path, icon: "layers",
          test: "member-nav-environments", visible: can_view_environments?, active: cp == "member/environments" },
        { label: "member.nav.organization", path: edit_member_organization_path, icon: "building",
          test: "member-nav-organization", visible: can?("organization.manage"),
          active: cp == "member/organizations" },
        { label: "member.nav.guidance", path: member_organization_guidance_path, icon: "compass",
          test: "member-nav-guidance", visible: can?("organization.manage"),
          active: cp.start_with?("member/organization_guidance") },
        { label: "member.nav.organization_ai", path: member_organization_ai_path, icon: "sparkles",
          test: "member-nav-organization-ai", visible: can?("ai.manage"), active: cp == "member/organization_ai" },
        # Who did what and when, across four areas: a question about the whole organization (CYRA-745).
        { label: "member.nav.activity", path: member_activity_path, icon: "history",
          test: "member-nav-activity", visible: can?("activity.view"),
          active: cp == "member/activity" },
        # The list of connectable services; the GitHub App is one of its tabs (CYRA-581, CYRA-545).
        { label: "member.nav.integrations", path: member_integrations_path, icon: "plug",
          test: "member-nav-integrations", visible: can?("organization.manage"),
          active: cp.start_with?("member/integrations") }
      ]
    end
  end
end
