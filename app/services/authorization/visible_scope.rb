# frozen_string_literal: true

module Authorization
  # Che cosa vede, di ogni dominio, chi sta guardando: UN oggetto per richiesta, ricevuto da chi ne
  # ha bisogno invece di quaranta metodi ereditati dalla base dei controller (CYRA-799).
  #
  #
  # Il confine è il LINKAGE ai progetti e tutto il resto discende da lì. "Vede tutto" SOLO owner
  # (+god); altrimenti union dei link personali (Group/ProjectMembership) e dei link dei team a cui
  # l'account appartiene (TeamGroup/TeamProjectAccess). Zero link → relation vuota (strict). Lo scope
  # segue i gruppi: un nuovo progetto in un gruppo collegato è subito visibile.
  class VisibleScope
    # owner della org o god → unscoped. (god incluso anche senza membership.)
    def self.unscoped?(account:, organization:)
      return false if account.nil? || organization.nil?
      return true if account.god?

      Connections::Membership.exists?(account_id: account.id,
                                      organization_id: organization.id,
                                      role: :owner)
    end

    # CYRA-799 — `true_account` è chi sta guardando DAVVERO (regge l'impersonation: un god che
    # impersona vede ancora tutto). `permits_area` è il verdetto del gate per le risorse org-level:
    # una lambda `->(area) { true/false }`, perché la regola dei permessi resta a PermissionGates.
    def initialize(account:, organization:, true_account: nil, permits_area: nil)
      @account = account
      @organization = organization
      @true_account = true_account
      @permits_area = permits_area
    end

    # Chi guarda è god: scavalca il linkage in ogni dominio. Senza `true_account` (service fuori dalla
    # richiesta web) resta il god dell'account stesso.
    def god?
      return @god if defined?(@god)

      @god = (@true_account || @account)&.god? || false
    end

    def unscoped?
      return @unscoped if defined?(@unscoped)

      @unscoped = god? || self.class.unscoped?(account: @account, organization: @organization)
    end

    # ActiveRecord::Relation dei progetti visibili nell'org.
    def projects
      base = @organization.projects
      return base if unscoped?

      base.where(group_id: visible_group_ids).or(base.where(id: visible_project_ids))
    end

    # ActiveRecord::Relation dei gruppi-di-progetti visibili nell'org (gemello di #projects).
    def groups
      base = @organization.groups
      return base if unscoped?

      base.where(id: visible_group_ids)
    end

    # --- Gli elenchi di ogni dominio (CYRA-799) -----------------------------------------------
    # Discendono TUTTI dai progetti visibili: un ticket è visibile se lo è il suo progetto, un errore
    # pure, e così via. Chi aggiunge un dominio scrive una riga qui, non una seconda regola.
    def coworker_puckies = Coworkers::Puck.where(organization: @organization, account: @account)
    def tickets = of_visible_projects(Ticketing::Ticket)
    def ideas = of_visible_projects(Ideas::Idea)
    def helpdesk_requests = of_visible_projects(Helpdesk::Request)
    def error_groups = of_visible_projects(Errors::Group)
    def traces = of_visible_projects(Traces::Trace)
    def replay_sessions = of_visible_projects(Replays::Session)
    def monitors = of_visible_projects(Uptime::Monitor)
    def metric_groups = of_visible_projects(Metrics::Group)
    def cron_monitors = of_visible_projects(Crons::Monitor)
    def logs = of_visible_projects(Logs::Entry)
    def vulnerabilities = of_visible_projects(Vulnerabilities::Finding)
    def runtime_statuses = of_visible_projects(Vulnerabilities::RuntimeStatus)
    def datasets = of_visible_projects(Datasets::Dataset)

    # I lockfile noti dei progetti visibili: dicono su quale pezzo del progetto l'elenco delle
    # vulnerabilità non ha nulla da dire (CYRA-810).
    def vulnerability_manifests = of_visible_projects(Vulnerabilities::Manifest)

    # SEO (CYRA-528): la lettura la governa l'accesso al progetto, non esiste una chiave `seo.view`.
    # Rilievi e pagine discendono dai siti, che discendono dai progetti.
    def seo_sites = of_visible_projects(Seo::Site)
    def seo_issues = Seo::Issue.where(site_id: seo_sites.select(:id))
    def seo_pages = Seo::Page.where(site_id: seo_sites.select(:id))

    # Pagine KB: NON un `where(project_id:)` come le altre risorse — sono N:N su progetti/gruppi (o
    # org-wide), quindi la regola sta in Knowledge::Page.visible_to. Il ramo god filtra comunque per
    # stato, o le proposte in revisione comparirebbero in ricerca e liste per il solo god.
    def pages(status: :published)
      return Knowledge::Page.where(organization_id: @organization.id, status: status) if god?

      Knowledge::Page.visible_to(
        account: @account, organization: @organization, full_access: unscoped?,
        visible_project_ids: projects.select(:id), visible_group_ids: groups.select(:id),
        status: status
      )
    end

    # La coda di revisione (CYRA-298): stessa visibilità delle pagine normali, cambia solo lo stato.
    def pages_in_review = pages(status: :in_review)

    # Book KB (CYRA-415): quelli con almeno un progetto visibile (diretto o via gruppo). Anti-leak
    # sulla show di una pagina vista da un altro scope in comune.
    def books
      base = Knowledge::Book.where(organization_id: @organization.id)
      return base if god?

      base.visible_within(projects.select(:id))
    end

    # Team dell'org di cui l'account è membro: alimenta i form workload, i filtri e la voce di menu.
    def teams = @account.teams.where(organization_id: @organization.id)

    # Workload: team-scoped, non per-progetto né a permesso. Lo stesso confine autorizza le scritture
    # (Member::Workload::ActionsController risolve da qui → 404 anti-BOLA per altri team).
    def workload_actions
      Workload::Action.visible_to(account: @account, organization: @organization)
                      .includes(:team, :participants, :ticket, :created_by)
    end

    # Host di server monitoring e gruppi di monitor uptime: risorse ORG-LEVEL, la visibilità è a
    # permesso e non a linkage. Il verdetto arriva da chi costruisce lo scope (PermissionGates resta
    # l'unico posto in cui la regola del permesso è scritta): senza gate collegato, elenco vuoto.
    def servers
      return Servers::Host.none unless permits_area?("servers")

      Servers::Host.where(organization_id: @organization.id)
    end

    # Kubernetes clusters (CYAG-22): org-level like the servers, under the same permission area.
    def clusters
      return Clusters::Cluster.none unless permits_area?("servers")

      Clusters::Cluster.where(organization_id: @organization.id)
    end

    def uptime_groups
      return Uptime::Group.none unless permits_area?("uptime_groups")

      @organization.uptime_groups
    end

    # Id dei gruppi-di-progetti visibili (personali + via team). Utile a chi compone query.
    # Memoizzato: una singola VisibleScope viene interrogata più volte per richiesta (projects + groups
    # + can_any?) — senza memo le stesse pluck ripartono a ogni chiamata (prosopite le vede N+1).
    def visible_group_ids
      @visible_group_ids ||= (personal_group_ids + team_group_ids).uniq
    end

    # Id dei progetti collegati direttamente (personali + via team).
    def visible_project_ids
      @visible_project_ids ||= (personal_project_ids + team_project_ids).uniq
    end

    # Batch: { account_id => Set(project_ids visibili) } per N account in un numero FISSO di query
    # (indipendente dal numero di account), mirror della semantica di #projects. Serve a chi deve
    # valutare la visibilità di PIÙ account insieme (Chat::CommonScope) senza istanziare una
    # VisibleScope per account — che rifarebbe le stesse pluck a fingerprint ripetuta (prosopite N+1).
    def self.project_ids_by_account(accounts:, organization:)
      accounts = Array(accounts).compact.uniq(&:id)
      return {} if accounts.empty? || organization.nil?

      account_ids = accounts.map(&:id)
      all_project_ids = organization.projects.pluck(:id)
      # owner/god → unscoped. god in memoria; owner in UNA query (non un exists? per account = N+1).
      unscoped_ids = accounts.select(&:god?).map(&:id).to_set
      unscoped_ids += Connections::Membership.where(account_id: account_ids, organization_id: organization.id, role: :owner).pluck(:account_id)

      group_ids_by_account = ids_grouped(
        Connections::GroupMembership.joins(:group)
          .where(account_id: account_ids, projects_groups: { organization_id: organization.id })
          .pluck(:account_id, :group_id)
      )
      direct_by_account = ids_grouped(
        Connections::ProjectMembership.joins(:project)
          .where(account_id: account_ids, projects: { organization_id: organization.id })
          .pluck(:account_id, :project_id)
      )
      team_ids_by_account = ids_grouped(
        Connections::TeamMembership.joins(:team)
          .where(account_id: account_ids, teams_teams: { organization_id: organization.id })
          .pluck(:account_id, :team_id)
      )

      all_team_ids = team_ids_by_account.values.flatten.uniq
      team_group_by_team = ids_grouped(Connections::TeamGroupAccess.where(team_id: all_team_ids).pluck(:team_id, :group_id)) unless all_team_ids.empty?
      team_project_by_team = ids_grouped(Connections::TeamProjectAccess.where(team_id: all_team_ids).pluck(:team_id, :project_id)) unless all_team_ids.empty?
      team_group_by_team ||= {}
      team_project_by_team ||= {}

      # gruppo → progetti (una query per TUTTI i gruppi coinvolti) per espandere i group_ids in project_ids.
      involved_group_ids = (group_ids_by_account.values + team_group_by_team.values).flatten.uniq
      projects_by_group = ids_grouped(
        involved_group_ids.empty? ? [] : organization.projects.where(group_id: involved_group_ids).pluck(:group_id, :id)
      )

      accounts.index_with do |account|
        next all_project_ids.to_set if unscoped_ids.include?(account.id)

        team_ids = team_ids_by_account[account.id] || []
        group_ids = (group_ids_by_account[account.id] || []) + team_ids.flat_map { |t| team_group_by_team[t] || [] }
        project_ids = (direct_by_account[account.id] || []) + team_ids.flat_map { |t| team_project_by_team[t] || [] }
        project_ids += group_ids.flat_map { |g| projects_by_group[g] || [] }
        project_ids.to_set
      end.transform_keys { |account| account.id }
    end

    # [[k, v], ...] → { k => [v, ...] }. Helper interno per il batch.
    def self.ids_grouped(pairs)
      pairs.each_with_object({}) { |(k, v), acc| (acc[k] ||= []) << v }
    end
    private_class_method :ids_grouped

    private

    # Il confine, scritto una volta: la risorsa vive nel progetto, il progetto è visibile o non lo è.
    def of_visible_projects(model) = model.where(project_id: projects.select(:id))

    # Il verdetto del gate, chiesto una volta per area: la sidebar attraversa la stessa voce più
    # volte per render, e ogni domanda è una valutazione RBAC.
    def permits_area?(area)
      return false if @permits_area.nil?

      @permitted_areas ||= {}
      @permitted_areas.fetch(area) { @permitted_areas[area] = @permits_area.call(area) }
    end

    def team_ids
      @team_ids ||= @account.teams.where(organization_id: @organization.id).pluck(:id)
    end

    def personal_group_ids
      @personal_group_ids ||= @account.accessible_groups.where(organization_id: @organization.id).pluck(:id)
    end

    def personal_project_ids
      @personal_project_ids ||= @account.directly_accessible_projects.where(organization_id: @organization.id).pluck(:id)
    end

    def team_group_ids
      @team_group_ids ||= team_ids.empty? ? [] : Connections::TeamGroupAccess.where(team_id: team_ids).pluck(:group_id)
    end

    def team_project_ids
      @team_project_ids ||= team_ids.empty? ? [] : Connections::TeamProjectAccess.where(team_id: team_ids).pluck(:project_id)
    end
  end
end
