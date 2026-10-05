# frozen_string_literal: true

module Product
  # Versioni indicabili per una cella: le release dei progetti del prodotto che girano su quella
  # piattaforma. Query object (nessuna mutazione, nessun Result) usato solo dal form della cella —
  # mai dalla matrice, dove sarebbe una query per colonna.
  #
  # projects_releases è unico su [project_id, version, environment]: la stessa versione esiste su
  # più ambienti. La matrice risponde a "da quale versione è nelle mani degli utenti", quindi si
  # preferisce production; ma un progetto che non ha NESSUNA release in production mostra tutti i
  # suoi ambienti, altrimenti la tendina resterebbe vuota e non ci sarebbe modo di procedere.
  class ReleaseCandidates
    PREFERRED_ENVIRONMENT = ::Projects::Release::DEFAULT_ENVIRONMENT
    LIMIT = 60

    # `selected`: la versione già indicata sulla cella. Va sempre inclusa, anche se il limite la
    # taglierebbe fuori (un progetto con ingest attivo accumula centinaia di release): altrimenti
    # la tendina non la contiene, il browser rimanda "non indicata" e un salvataggio qualsiasi
    # cancellerebbe la versione senza che nessuno l'abbia chiesto.
    def self.for(group:, platform:, limit: LIMIT, selected: nil)
      new(group: group, platform: platform, limit: limit, selected: selected).call
    end

    def initialize(group:, platform:, limit: LIMIT, selected: nil)
      @group = group
      @platform = platform
      @limit = limit
      @selected = selected
    end

    def call
      return Array(@selected) if project_ids.empty?

      base = ::Projects::Release.where(project_id: project_ids)
      production = base.where(environment: PREFERRED_ENVIRONMENT)
      without_production = project_ids - production.distinct.pluck(:project_id)

      candidates = production.or(base.where(project_id: without_production))
                             .preload(:project)
                             .order(ordering)
                             .limit(@limit)
                             .to_a

      return candidates if @selected.nil? || candidates.any? { |release| release.id == @selected.id }

      candidates.unshift(@selected)
    end

    private

    def project_ids
      @project_ids ||= ::Projects::Project
                       .where(group_id: @group.id)
                       .where(id: ::Connections::ProjectPlatform.where(platform_id: @platform.id).select(:project_id))
                       .pluck(:id)
    end

    # `current` prima (è la versione che gira ora), poi la più recente. deployed_at è valorizzato
    # solo dal binding dei tag GitHub: le release nate dall'ingest ce l'hanno nil e un ORDER BY
    # secco le spedirebbe tutte in fondo, cioè quasi tutte.
    def ordering
      Arel.sql(
        "projects_releases.current DESC, " \
        "COALESCE(projects_releases.deployed_at, projects_releases.first_event_at, projects_releases.created_at) DESC"
      )
    end
  end
end
