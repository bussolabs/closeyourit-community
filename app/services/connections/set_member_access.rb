# frozen_string_literal: true

module Connections
  # Imposta gli accessi scoped di un account in un'org: sostituisce l'insieme dei gruppi e dei
  # progetti assegnati (idempotente), SOLO per gli id dell'org corrente (anti-BOLA; altri scartati).
  # Preserva le assegnazioni in altre org: le join non hanno organization_id, quindi il reconcile
  # tocca solo le righe i cui gruppi/progetti appartengono a @organization. Transazionale. Result pattern.
  #
  # `actor:` (CYRA-237): quando presente e NON unscoped (owner/god), Authorization::ScopeGuard riconcilia
  # richiesto+corrente sotto la visibilità dell'attore. Non può concedere — a sé o ad altri — progetti/gruppi
  # che non vede già (AGGIUNTA fuori-visibilità → R403-ACCESS-001, fail-closed prima della transazione), ma
  # lo scope preesistente che non vede resta INTATTO (né iniettabile né cancellabile). actor nil (seed/
  # preview) → passthrough senza vincolo.
  class SetMemberAccess < ApplicationService
    def initialize(organization:, account:, group_ids:, project_ids:, actor: nil)
      @organization = organization
      @account = account
      @group_ids = Array(group_ids).reject(&:blank?)
      @project_ids = Array(project_ids).reject(&:blank?)
      @actor = actor
    end

    def call
      plan = Authorization::ScopeGuard.plan(
        actor: @actor, organization: @organization,
        project_ids: requested_project_ids, current_project_ids: current_project_ids,
        group_ids: requested_group_ids, current_group_ids: current_group_ids
      )
      return Result.err(plan.barrier) if plan.barrier

      ActiveRecord::Base.transaction do
        sync_groups(plan.group_ids)
        sync_projects(plan.project_ids)
      end
      Result.ok(@account)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: "R422-ACCESS-001", details: e.record&.errors&.to_hash))
    end

    private

    # Richiesto ristretto all'org (anti-BOLA cross-org: gli id di altre org sono scartati qui).
    def requested_project_ids
      @requested_project_ids ||= @organization.projects.where(id: @project_ids).ids
    end

    def requested_group_ids
      @requested_group_ids ||= @organization.groups.where(id: @group_ids).ids
    end

    # Corrente ristretto all'org (le join non hanno organization_id → filtro sui progetti/gruppi dell'org).
    def current_project_ids
      @account.project_memberships.where(project_id: @organization.projects.select(:id)).pluck(:project_id)
    end

    def current_group_ids
      @account.group_memberships.where(group_id: @organization.groups.select(:id)).pluck(:group_id)
    end

    def sync_groups(keep)
      org_group_ids = @organization.groups.select(:id)
      @account.group_memberships.where(group_id: org_group_ids).where.not(group_id: keep).destroy_all
      existing = @account.group_memberships.where(group_id: keep).pluck(:group_id)
      (keep - existing).each { |gid| @account.group_memberships.create!(group_id: gid) }
    end

    def sync_projects(keep)
      org_project_ids = @organization.projects.select(:id)
      @account.project_memberships.where(project_id: org_project_ids).where.not(project_id: keep).destroy_all
      existing = @account.project_memberships.where(project_id: keep).pluck(:project_id)
      (keep - existing).each { |pid| @account.project_memberships.create!(project_id: pid) }
    end
  end
end
