# frozen_string_literal: true

module Authorization
  # Guard anti privilege-escalation sullo SCOPE: "non puoi CONCEDERE progetti o gruppi che non vedi".
  # Gemello di Authorization::GrantGuard (CHIAVI, CYRA-156); qui il confine è la VISIBILITÀ
  # (Authorization::VisibleScope). Condiviso dai setter full-replace di scope (Connections::SetMemberAccess
  # + Teams::SetTeamScope): #plan riconcilia l'insieme RICHIESTO con quello CORRENTE sotto la visibilità
  # dell'attore, così un attore scoped opera SOLO dentro ciò che vede.
  class ScopeGuard
    # Piano di reconcile: gli id da persistere (keep) per asse + la barriera (AppError R403 o nil).
    Plan = Struct.new(:project_ids, :group_ids, :barrier, keyword_init: true)

    # actor nil (seed/preview/system) o unscoped (owner/god) → nessun vincolo: keep = richiesto (full-replace).
    # Attore scoped, per ogni asse (progetti, gruppi):
    #   - keep = (corrente FUORI dalla sua visibilità, PRESERVATO) ∪ (richiesto DENTRO la sua visibilità).
    #     Non cancella uno scope preesistente che non vede (ometterlo non lo tocca) né lo riconferma come
    #     escalation (includerlo se già presente è lecito). Dentro la visibilità resta full-replace.
    #   - forbidden = AGGIUNTE richieste fuori-visibilità (id non già presente) → barrier R403-ACCESS-001.
    # Gli id in ingresso devono essere già ristretti all'org (i chiamanti fanno organization.*.where(id:).ids):
    # gli id di un'altra org non arrivano qui → restano scarto silenzioso anti-BOLA nel service.
    def self.plan(actor:, organization:, project_ids:, current_project_ids:, group_ids:, current_group_ids:)
      scoped = actor && !Authorization::VisibleScope.unscoped?(account: actor, organization: organization)
      return Plan.new(project_ids: project_ids, group_ids: group_ids, barrier: nil) unless scoped

      visible = Authorization::VisibleScope.new(account: actor, organization: organization)
      p_keep, p_forbidden = reconcile(requested: project_ids, current: current_project_ids, visible: visible.projects.ids)
      g_keep, g_forbidden = reconcile(requested: group_ids, current: current_group_ids, visible: visible.groups.ids)

      Plan.new(project_ids: p_keep, group_ids: g_keep, barrier: barrier_for(p_forbidden, g_forbidden))
    end

    # keep = corrente-fuori-visibilità (preservato) + richiesto-visibile; forbidden = aggiunte fuori-visibilità.
    def self.reconcile(requested:, current:, visible:)
      visible = visible.to_set
      forbidden = requested.reject { |id| visible.include?(id) || current.include?(id) }
      keep = current.reject { |id| visible.include?(id) } + requested.select { |id| visible.include?(id) }
      [ keep.uniq, forbidden ]
    end
    private_class_method :reconcile

    def self.barrier_for(forbidden_projects, forbidden_groups)
      return if forbidden_projects.empty? && forbidden_groups.empty?

      AppError.new(
        "Non puoi assegnare progetti o gruppi che non vedi",
        code: "R403-ACCESS-001", status: :forbidden,
        details: { forbidden_project_ids: forbidden_projects, forbidden_group_ids: forbidden_groups }
      )
    end
    private_class_method :barrier_for
  end
end
