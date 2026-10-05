# frozen_string_literal: true

module Teams
  # Imposta lo scope di un team (progetti + gruppi collegati): sostituisce l'insieme (idempotente),
  # SOLO per gli id dell'org del team (anti-BOLA). Transazionale, audit sync. Result pattern.
  #
  # `actor:` (CYRA-237): quando presente e NON unscoped (owner/god), Authorization::ScopeGuard riconcilia
  # richiesto+corrente sotto la visibilità dell'attore: non può concedere al team progetti/gruppi che non
  # vede già (AGGIUNTA fuori-visibilità → R403-ACCESS-001 prima della transazione), ma lo scope preesistente
  # che non vede resta INTATTO. Chiude il canale-team dell'escalation sullo scope (gate permissions.manage).
  #
  # Sentinel `:unchanged` (CYCL-62, stessa convenzione di Uptime::Monitors::Save): un asse non passato
  # resta com'è. Serviva perché i due assi arrivano insieme e `Array(nil) => []` svuotava quello omesso —
  # `teams update --group X` cancellava tutti i progetti del team. Una lista vuota resta lo svuotamento.
  class SetTeamScope < ApplicationService
    UNCHANGED = :unchanged

    def initialize(team:, group_ids: UNCHANGED, project_ids: UNCHANGED, actor: nil, true_actor: nil)
      @team = team
      @organization = team.organization
      @group_ids = group_ids
      @project_ids = project_ids
      @actor = actor
      @true_actor = true_actor
    end

    def call
      p_current = @team.project_accesses.pluck(:project_id)
      g_current = @team.group_accesses.pluck(:group_id)
      plan = Authorization::ScopeGuard.plan(
        actor: @actor, organization: @organization,
        project_ids: requested(@project_ids, @organization.projects, p_current), current_project_ids: p_current,
        group_ids: requested(@group_ids, @organization.groups, g_current), current_group_ids: g_current
      )
      return Result.err(plan.barrier) if plan.barrier

      ActiveRecord::Base.transaction do
        p_add, p_remove = sync(@team.project_accesses, :project_id, plan.project_ids, p_current)
        g_add, g_remove = sync(@team.group_accesses, :group_id, plan.group_ids, g_current)
        audit(p_add, p_remove, g_add, g_remove)
      end
      Result.ok(@team)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: "R422-ACCESS-002", details: e.record.errors.to_hash))
    end

    private

    # Gli id richiesti per un asse, ristretti all'org (anti-BOLA). Sentinel → l'insieme corrente, quindi
    # il piano non vede né aggiunte né rimozioni su quell'asse.
    def requested(ids, relation, current)
      return current if ids == UNCHANGED

      relation.where(id: Array(ids).reject(&:blank?)).ids
    end

    def sync(association, fk, keep, current)
      remove = current - keep
      add = keep - current
      association.where(fk => remove).destroy_all if remove.any?
      add.each { |id| association.create!(fk => id) }
      [ add, remove ]
    end

    def audit(p_add, p_remove, g_add, g_remove)
      return unless [ p_add, p_remove, g_add, g_remove ].any?(&:any?)

      Authorization::RecordChange.call(
        organization: @organization, action: "team_scope_changed",
        actor: @actor, true_actor: @true_actor,
        data: {
          team: @team.name,
          projects_added: names(@organization.projects, p_add),
          projects_removed: names(@organization.projects, p_remove),
          groups_added: names(@organization.groups, g_add),
          groups_removed: names(@organization.groups, g_remove)
        }
      )
    end

    def names(rel, ids)
      ids.any? ? rel.where(id: ids).pluck(:name) : []
    end
  end
end
