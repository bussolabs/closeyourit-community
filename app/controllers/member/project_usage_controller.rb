# frozen_string_literal: true

module Member
  # Uso del prodotto per UN progetto (tab Uso, CYRA-733): che cosa è stato aperto davvero — le
  # funzioni (`feature_view`, la chiave stabile del catalogo) e le pagine (`route`), più i lavori di
  # fondo che un SDK dichiara. Il canale che riempie questa tabella è quello di CYSK-29: qui si
  # legge, non si scrive.
  #
  # La pagina risponde a una domanda sola — «questa parte serve ancora?» — e non pretende di
  # rispondere al suo contrario: un simbolo che non compare può non essere mai stato aperto oppure
  # non essere mai stato dichiarato da nessun SDK. Il verdetto «inutilizzato» richiede l'inventario
  # statico del repository e resta dello scanner, come per la rilettura da terminale.
  #
  # Controller flat (come ProjectDocumentsController) per non ombreggiare il namespace ::Projects.
  class ProjectUsageController < Member::BaseController
    permission_not_required "L'uso di un progetto visibile è materiale di prodotto, non un segreto: dice quali " \
                            "funzioni vengono aperte, mai da chi. Stesso confine della rilettura da terminale, " \
                            "dove il gate è la visibilità del progetto e non una chiave a parte."

    # CYRA-924 — a register sorts on its dates only.
    SORT_COLUMNS = { "first_seen" => :first_seen_at, "last_seen" => :last_seen_at }.freeze

    before_action :set_project

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :kind, :environment, only: :show

    def show
      scope = ::Usage::Symbol.where(project_id: @project.id)
      @counts = counts_for(scope)
      @environments = scope.distinct.pluck(:environment).compact.sort
      @pagination = paginate(sorted(filtered(scope).recent_first, columns: SORT_COLUMNS))
      @symbols = @pagination.records
      @stats = @project.ticket_tally
    end

    private

    # Anti-BOLA + scoping: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def filtered(relation)
      relation = relation.where(kind: params[:kind]) if params[:kind].present?
      relation = relation.where(environment: params[:environment]) if params[:environment].present?
      relation
    end

    # Chip del titolo: quanto è stato visto in tutto, e come si divide fra funzioni di prodotto e
    # pagine. Conteggi sull'INTERO progetto (non sui filtri): dicono cosa c'è da guardare, e un
    # filtro attivo non deve poterli far sembrare zero. Un solo group by, nessuna query per chip.
    def counts_for(scope)
      per_kind = scope.group(:kind).count
      { total: per_kind.values.sum, features: per_kind["feature_view"].to_i, routes: per_kind["route"].to_i }
    end
  end
end
