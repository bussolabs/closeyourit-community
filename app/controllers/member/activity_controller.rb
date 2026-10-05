# frozen_string_literal: true

module Member
  # CYRA-745 — «Chi ha fatto cosa e quando»: la pagina che mancava. Le azioni delle persone erano
  # scritte in registri separati, uno per dominio, e quello dei PERMESSI non lo leggeva nessuna pagina:
  # alla domanda «chi ha dato questo permesso, e quando» il prodotto non rispondeva pur avendo il dato.
  #
  # Sola LETTURA. L'unione avviene in Activity::AuditQuery, non riscrivendo lo storico in una tabella
  # sola: i registri dei segreti sono append-only e immutabili per costruzione.
  #
  # DUE gate che si SOMMANO. `activity.view` apre la pagina; le righe del Vault entrano solo per chi ha
  # ANCHE `secrets_audit.view` — altrimenti questa pagina sarebbe la porta di servizio per leggere
  # l'audit dei segreti senza il permesso che lo protegge.
  class ActivityController < Member::BaseController
    before_action :require_activity_view

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :source, :event_action, :actor_id, :from, :to, only: :index

    def index
      @pagination = Activity::AuditQuery.page(page: params[:page], per: requested_per(Pagination::DEFAULT_PER),
                                              **query_options)
      @rows = @pagination.records
      @projects = visible.projects.index_by(&:id)
      @actors = actors_for_filter
      @source_filter = params[:source].presence
    end

    private

    def require_activity_view
      require_permission!("activity.view")
    end

    # Il perimetro dell'account, non quello dell'organizzazione: i registri raccolgono azioni su
    # progetti e team, e sono quelli a decidere cosa si può leggere. `visible.teams` è lo stesso
    # criterio di Workload::Action.visible_to.
    def query_options
      {
        organization: Current.organization,
        visible_project_ids: visible.projects.pluck(:id),
        visible_team_ids: visible.teams.pluck(:id),
        include_secrets: can?("secrets_audit.view"),
        include_moves: current_membership&.owner? || false,
        filters: activity_filters,
        oldest_first: oldest_first?
      }
    end

    # CYRA-924 — the register sorts on the date only: any other column would read every register whole.
    def oldest_first? = current_sort == [ "occurred_at", :asc ]

    # `action` è riservato (nome dell'azione controller) → il filtro azione viaggia come
    # `event_action`, come sulla pagina Attività del Vault.
    def activity_filters
      {
        source: params[:source].presence,
        action: params[:event_action].presence,
        actor_id: params[:actor_id].presence,
        from: time_bound(:from),
        to: time_bound(:to)
      }
    end

    # Le persone dell'organizzazione che possono comparire nel registro. Si legge dalle membership e
    # non dalle righe: contare i distinti attori su quattro registri costerebbe quattro query in più a
    # ogni apertura della pagina, per una tendina che l'organizzazione ha già in elenco.
    def actors_for_filter
      Accounts::Account
        .joins(:memberships)
        .where(memberships: { organization_id: Current.organization.id })
        .order(:email)
    end
  end
end
