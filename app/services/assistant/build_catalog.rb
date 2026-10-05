# frozen_string_literal: true

module Assistant
  # Costruisce il CATALOGO delle funzioni del sistema che l'assistente può suggerire, filtrato ai soli
  # strumenti che l'utente può davvero usare (RBAC-aware). È la fonte del system prompt: l'assistente
  # non deve mai indirizzare verso una funzione bloccata dai permessi.
  #
  # Registry dichiarativo FUNCTIONS: per ogni voce il route helper (il path viene dalla ROTTA reale →
  # link non allucinabili, no drift) e la chiave permesso org-level richiesta (nil = baseline, visibile
  # a chiunque veda l'organizzazione). Il gating riusa lo stesso Authorization::Resolver dei controller
  # (owner/god → tutto). Le funzioni gated da permessi PER-PROGETTO (es. datasets) restano fuori dal v1:
  # richiederebbero uno scope, e un catalogo "in generale" non ne ha uno.
  class BuildCatalog < ApplicationService
    Function = Data.define(:key, :label, :description, :path)

    FUNCTIONS = [
      # --- Baseline: chi vede l'organizzazione le vede (nessun permesso richiesto) ----------------
      { key: "tickets",            helper: :member_tickets_path,                    permission: nil },
      { key: "ideas",              helper: :member_ideas_path,                      permission: nil },
      { key: "knowledge",          helper: :member_knowledge_pages_path,            permission: nil },
      { key: "workload",           helper: :member_workload_actions_path,           permission: nil },
      { key: "todos",              helper: :member_todo_lists_path,                 permission: nil },
      { key: "projects",           helper: :member_projects_path,                   permission: nil },
      { key: "errors",             helper: :member_monitoring_error_groups_path,    permission: nil },
      { key: "performance",        helper: :member_monitoring_metric_groups_path,   permission: nil },
      { key: "logs",               helper: :member_monitoring_log_entries_path,     permission: nil },
      { key: "uptime",             helper: :member_monitoring_monitors_path,        permission: nil },
      { key: "crons",              helper: :member_monitoring_cron_monitors_path,   permission: nil },
      { key: "analytics",          helper: :member_monitoring_analytics_path,       permission: nil },
      { key: "personal_variables", helper: :member_personal_secrets_path,           permission: nil },
      { key: "personal_files",     helper: :member_personal_secret_assets_path,     permission: nil },
      { key: "project_secrets",    helper: :member_vault_projects_path,             permission: nil },
      { key: "guides",             helper: :member_guides_path,                     permission: nil },
      { key: "changelog",          helper: :member_changelog_path,                  permission: nil },
      # --- Gated da un permesso org-level ---------------------------------------------------------
      { key: "alerts",             helper: :member_alerting_rules_path,             permission: "alerts.manage" },
      { key: "servers",            helper: :member_monitoring_servers_path,         permission: "servers.view",      manage: "servers.manage" },
      { key: "agents",             helper: :member_agents_path,                     permission: "agents.view",       manage: "agents.manage" },
      { key: "members",            helper: :member_members_path,                    permission: "members.view",      manage: "members.manage" },
      { key: "service_accounts",   helper: :member_service_accounts_path,           permission: "members.manage" },
      { key: "teams",              helper: :member_teams_path,                      permission: "permissions.manage" },
      { key: "roles",              helper: :member_roles_path,                      permission: "permissions.manage" },
      { key: "platforms",          helper: :member_platforms_path,                  permission: "platforms.view",    manage: "platforms.manage" },
      { key: "environments",       helper: :member_environments_path,               permission: "environments.view", manage: "environments.manage" },
      { key: "organization",       helper: :edit_member_organization_path,          permission: "organization.manage" },
      { key: "shared_variables",   helper: :member_shared_secrets_path,             permission: "shared_secrets.manage" },
      { key: "shared_files",       helper: :member_shared_secret_assets_path,       permission: "shared_secret_files.manage" },
      { key: "vault_audit",        helper: :member_vault_audit_path,                permission: "secrets_audit.view" },
      { key: "activity",           helper: :member_activity_path,                   permission: "activity.view" }
    ].freeze

    def initialize(account:, organization:, resolver: nil)
      @account = account
      @organization = organization
      @resolver = resolver
    end

    # Ritorna un array di Function (chiave, etichetta, descrizione, path) per le funzioni visibili.
    def call
      resolver = @resolver || Authorization::Resolver.new(account: @account, organization: @organization)
      routes = Rails.application.routes.url_helpers

      FUNCTIONS.filter_map do |f|
        # manage-implies-view: le pagine con `manage:` sono raggiungibili anche col solo permesso di
        # gestione, come i gate `require_permission!(".view") unless can?(".manage")` nei controller.
        # Senza, un utente con solo `X.manage` non vedrebbe la funzione pur potendo aprirne la pagina.
        next if f[:permission] && !resolver.can?(f[:permission]) && !(f[:manage] && resolver.can?(f[:manage]))

        Function.new(
          key: f[:key],
          label: I18n.t("member.assistant.catalog.#{f[:key]}.label"),
          description: I18n.t("member.assistant.catalog.#{f[:key]}.description"),
          path: routes.public_send(f[:helper])
        )
      end
    end
  end
end
