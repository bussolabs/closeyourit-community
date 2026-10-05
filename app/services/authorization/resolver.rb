# frozen_string_literal: true

require "set"

module Authorization
  # Cuore RBAC. `can?(key, scope:)` decide se un account può fare un'azione, eventualmente su un
  # progetto. Gerarchia: god/owner → tutto; poi (scoped) lo scope dev'essere visibile; poi override
  # personale (allow/deny) che BATTE i ruoli; poi i ruoli effettivi (team + diretti) — per i permessi
  # scoped il soggetto che porta il ruolo dev'essere collegato allo scope (no leak cross-scope). I
  # ruoli sono LIVE: si leggono le chiavi correnti. Cache per-istanza (= per-richiesta) → niente N+1.
  class Resolver
    Decision = Data.define(:allowed, :origin)

    def initialize(account:, organization:)
      @account = account
      @organization = organization
    end

    def can?(key, scope: nil)
      decide(key, scope: scope).allowed
    end

    # Come can?(key, scope: project) ma per un GRUPPO di progetti: concesso a god/owner, altrimenti
    # richiede che il gruppo sia visibile e che un override personale o un soggetto (diretto o team)
    # con quella chiave sia collegato al gruppo. Serve a validare l'aggancio di scope a un gruppo
    # ancora VUOTO, dove non esiste alcun progetto effettivo su cui valutare can?(key, scope: project)
    # (CYRA-177). Additivo: non passa da scope_visible?/covers? (basati su project.group_id), così il
    # path dei permessi su progetto resta invariato.
    def can_group?(key, group)
      return true if @account&.god? || owner?
      return false unless @account && Authorization::Catalog.valid?(key) && Authorization::Catalog.scoped?(key)
      return false unless visible_group_ids.include?(group.id)

      override = personal_overrides[key]
      return override == "allow" unless override.nil?

      group_role_grant?(key, group)
    end

    # Restituisce anche l'origine (per la UI di spiegazione e i test).
    def decide(key, scope: nil)
      return Decision.new(true, :god) if @account&.god?
      return Decision.new(true, :owner) if owner?
      return Decision.new(false, :none) unless @account && Authorization::Catalog.valid?(key)

      scoped = Authorization::Catalog.scoped?(key)
      return Decision.new(false, :none) if scoped && !(scope && scope_visible?(scope))

      override = personal_overrides[key]
      unless override.nil?
        allow = (override == "allow")
        return Decision.new(allow, allow ? :personal_allow : :personal_deny)
      end

      granted = scoped ? scoped_role_grant?(key, scope) : org_role_keys.include?(key)
      granted ? Decision.new(true, :role) : Decision.new(false, :none)
    end

    private

    def owner?
      return @owner unless @owner.nil?

      @owner = Connections::Membership.exists?(account_id: @account&.id,
                                               organization_id: @organization.id, role: :owner)
    end

    def scope_visible?(project)
      visible_project_ids.include?(project.id)
    end

    # VisibleScope memoizzato: projects/groups condividono l'istanza → le pluck di linkage girano una
    # sola volta (no prosopite N+1) quando si valutano insieme scope-progetto e scope-gruppo.
    def visible_scope
      @visible_scope ||= Authorization::VisibleScope.new(account: @account, organization: @organization)
    end

    def visible_project_ids
      @visible_project_ids ||= visible_scope.projects.pluck(:id).to_set
    end

    def visible_group_ids
      @visible_group_ids ||= visible_scope.groups.pluck(:id).to_set
    end

    # Gemello di scoped_role_grant? per un GRUPPO: la chiave (da un ruolo personale o di team) e il
    # collegamento al gruppo devono provenire dallo STESSO soggetto (no leak cross-soggetto sui team).
    def group_role_grant?(key, group)
      return true if personal_role_keys.include?(key) && personal_group_ids.include?(group.id)

      team_subjects.any? { |t| t[:keys].include?(key) && t[:group_ids].include?(group.id) }
    end

    # { permission_key => "allow"/"deny" }
    def personal_overrides
      @personal_overrides ||= @account.account_permissions
                                      .where(organization_id: @organization.id)
                                      .each_with_object({}) { |ap, h| h[ap.permission_key] = ap.effect }
    end

    # Chiavi dei ruoli effettivi (team + diretti) — per i permessi ORG-LEVEL (nessuno scope).
    def org_role_keys
      @org_role_keys ||= (personal_role_keys + team_subjects.flat_map { |t| t[:keys] }).uniq
    end

    # Permesso SCOPED: serve un soggetto (diretto o team) che abbia la chiave E sia collegato allo scope.
    def scoped_role_grant?(key, project)
      if personal_role_keys.include?(key) && covers?(personal_project_ids, personal_group_ids, project)
        return true
      end

      team_subjects.any? do |t|
        t[:keys].include?(key) && covers?(t[:project_ids], t[:group_ids], project)
      end
    end

    # Lo scope (progetto) è coperto dai link diretti al progetto o al suo gruppo.
    def covers?(project_ids, group_ids, project)
      return true if project_ids.include?(project.id)

      project.group_id.present? && group_ids.include?(project.group_id)
    end

    def personal_role_keys
      @personal_role_keys ||= Authorization::RolePermission
                              .where(role_id: account_role_ids).distinct.pluck(:permission_key)
    end

    def account_role_ids
      @account_role_ids ||= Authorization::AccountRole
                            .where(account_id: @account.id, organization_id: @organization.id).pluck(:role_id)
    end

    def personal_project_ids
      @personal_project_ids ||=
        @account.directly_accessible_projects.where(organization_id: @organization.id).pluck(:id)
    end

    def personal_group_ids
      @personal_group_ids ||=
        @account.accessible_groups.where(organization_id: @organization.id).pluck(:id)
    end

    # Per ogni team dell'account nell'org: { keys:, project_ids:, group_ids: }. Preload in poche query.
    def team_subjects
      @team_subjects ||= compute_team_subjects
    end

    def compute_team_subjects
      team_ids = @account.teams.where(organization_id: @organization.id).pluck(:id)
      return [] if team_ids.empty?

      role_ids_by_team = group_pairs(Authorization::TeamRole.where(team_id: team_ids).pluck(:team_id, :role_id))
      all_role_ids = role_ids_by_team.values.flatten.uniq
      keys_by_role = group_pairs(Authorization::RolePermission.where(role_id: all_role_ids)
                                                              .pluck(:role_id, :permission_key))
      proj_by_team = group_pairs(Connections::TeamProjectAccess.where(team_id: team_ids)
                                                               .pluck(:team_id, :project_id))
      group_by_team = group_pairs(Connections::TeamGroupAccess.where(team_id: team_ids)
                                                              .pluck(:team_id, :group_id))

      team_ids.map do |tid|
        keys = (role_ids_by_team[tid] || []).flat_map { |rid| keys_by_role[rid] || [] }.uniq
        { keys: keys, project_ids: proj_by_team[tid] || [], group_ids: group_by_team[tid] || [] }
      end
    end

    # [[a, b], ...] → { a => [b, ...] }
    def group_pairs(pairs)
      pairs.group_by(&:first).transform_values { |rows| rows.map(&:last) }
    end
  end
end
