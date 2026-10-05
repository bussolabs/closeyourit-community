# frozen_string_literal: true

module Secrets
  # Ricerca cross-progetto delle variabili segrete per NOME (CYRA-424, evoluzione del primo taglio
  # CYRA-137): risponde a "dove è (e dove MANCA) VAR_X" tra i progetti VISIBILI dell'utente. Il match
  # per nome diventa una MATRICE progetto × ambiente: ogni riga è una coppia [nome, progetto] con una
  # cella per ogni ambiente ATTIVO del progetto, marcata presente o assente. Le assenze si calcolano
  # sugli ambienti attivi del SINGOLO progetto (mai su un elenco fisso: altrimenti falsi buchi), così
  # la domanda operativa «dove non c'è questa chiave» ha finalmente una risposta.
  #
  # Gate a monte = sola visibilità progetti (anti-BOLA, come l'index): NESSUN valore attraversa questo
  # service, solo la presenza del nome in [progetto, ambiente]. Aggregazione in memoria (poche
  # centinaia di righe), con preload mirato per non generare N+1 sugli ambienti dei progetti coinvolti.
  class VariableSearch
    Match = Data.define(:name, :project_id, :environment_id)

    # Cella della matrice: un ambiente e se la variabile vi è presente.
    Cell = Data.define(:environment, :present)

    # Riga di risultato: una chiave dentro un progetto, con le sue celle (una per ambiente attivo).
    Row = Data.define(:name, :project, :cells) do
      def cell_for(environment) = cells.find { |cell| cell.environment.id == environment.id }
      def present_count = cells.count(&:present)
      def absent_count = cells.count { |cell| !cell.present }
    end

    # Esito consumato dal controller/view: pagina corrente + opzioni filtro + conteggi.
    Result = Data.define(:query, :project_id, :environment_code, :sort,
                         :pagination, :total_absences, :project_options, :environment_options) do
      def rows = pagination.records
      def total_rows = pagination.total
      def blank? = query.blank?
      def any? = total_rows.positive?
    end

    SORTS = %w[name occurrences].freeze
    DEFAULT_SORT = "name"

    def self.call(...) = new(...).call

    def initialize(projects:, query:, project_id: nil, environment_code: nil, sort: nil, page: nil, per: nil)
      @projects = projects
      @query = query.to_s.strip
      @project_id = project_id.presence
      @environment_code = environment_code.presence
      @sort = SORTS.include?(sort.to_s) ? sort.to_s : DEFAULT_SORT
      @page = page
      @per = per
    end

    def call
      return blank_result if @query.blank?

      rows = build_rows
      rows = rows.select { |row| row.project.id == @project_id } if @project_id
      rows = sort_rows(rows)

      Result.new(
        query: @query, project_id: @project_id, environment_code: @environment_code, sort: @sort,
        pagination: Pagination.from_array(rows, page: @page, per: @per),
        total_absences: rows.sum(&:absent_count),
        project_options: project_options,
        environment_options: environment_options
      )
    end

    private

    # CYRA-842: nomi locali e nomi effettivi delle deleghe (stessa risoluzione di
    # Delegation#effective_name). Selezioniamo solo metadati: nessuna colonna cifrata viene caricata.
    # Escape dei metacaratteri LIKE: un "_" nel nome cercato non è un jolly.
    def matches
      @matches ||= (local_matches + delegated_matches).map { |attributes| Match.new(*attributes) }
    end

    def name_pattern
      "%#{::Secrets::Variable.sanitize_sql_like(@query)}%"
    end

    def local_matches
      ::Secrets::Variable
        .where(project_id: @projects.select(:id))
        .where("secrets_variables.name ILIKE ?", name_pattern)
        .pluck(:name, :project_id, :environment_id)
    end

    def delegated_matches
      effective_name = "COALESCE(secrets_shared_delegations.local_name, secrets_shared_variables.name)"
      ::Secrets::Shared::Delegation
        .joins(:project, shared_value: :shared_variable)
        .where(project_id: @projects.select(:id))
        .where("secrets_shared_variables.organization_id = projects.organization_id")
        .where("#{effective_name} ILIKE ?", name_pattern)
        .pluck(Arel.sql(effective_name), :project_id, "secrets_shared_values.environment_id")
    end

    # Progetti coinvolti coi loro ambienti preloadati: un colpo solo, così active_environments non
    # interroga per-progetto (guard N+1 Prosopite bloccante appena i progetti coinvolti sono >= 2).
    def projects_by_id
      @projects_by_id ||= ::Projects::Project
        .where(id: matches.map(&:project_id).uniq)
        .includes(:environments)
        .index_by(&:id)
    end

    # Presenze come Set di [project_id, environment_id, name] per lookup O(1) nella costruzione celle.
    def present_set
      @present_set ||= matches.map { |v| [ v.project_id, v.environment_id, v.name ] }.to_set
    end

    # Ambienti ATTIVI del progetto, nell'ordine della matrice (position, label). Filtra sull'array già
    # preloadato (niente `.active`, che rieseguirebbe una query ignorando il preload).
    def active_environments(project)
      project.environments.select(&:active?).sort_by { |env| [ env.position, env.label.downcase ] }
    end

    def build_rows
      matches.map { |v| [ v.name, v.project_id ] }.uniq.filter_map do |(name, project_id)|
        project = projects_by_id[project_id]
        next unless project

        environments = active_environments(project)
        environments = environments.select { |env| env.code == @environment_code } if @environment_code
        next if environments.empty?

        cells = environments.map { |env| Cell.new(environment: env, present: present_set.include?([ project_id, env.id, name ])) }
        Row.new(name: name, project: project, cells: cells)
      end
    end

    def sort_rows(rows)
      case @sort
      when "occurrences"
        rows.sort_by { |row| [ -row.present_count, row.name, row.project.name.downcase ] }
      else
        rows.sort_by { |row| [ row.name, row.project.name.downcase ] }
      end
    end

    # Progetti coinvolti (pre-filtro), per popolare la tendina del filtro progetto.
    def project_options
      projects_by_id.values.sort_by { |project| project.name.downcase }.map { |project| [ project.name, project.id ] }
    end

    # Ambienti coinvolti (pre-filtro), per la tendina del filtro ambiente. Distinti per code (org-level).
    def environment_options
      projects_by_id.values.flat_map { |project| active_environments(project) }
        .uniq(&:code).sort_by { |env| [ env.position, env.label.downcase ] }.map { |env| [ env.label, env.code ] }
    end

    def blank_result
      Result.new(query: @query, project_id: @project_id, environment_code: @environment_code, sort: @sort,
                 pagination: Pagination.from_array([], page: @page, per: @per),
                 total_absences: 0, project_options: [], environment_options: [])
    end
  end
end
