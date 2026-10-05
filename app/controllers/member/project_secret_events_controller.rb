# frozen_string_literal: true

module Member
  # Registro degli accessi ai secret di UN progetto (CYRA-77): la lista completa e filtrabile di ciò
  # che è successo al vault del progetto — letture, modifiche, tentativi bloccati — mentre la matrice
  # ne mostra solo le ultime righe. Controller flat (come ProjectSecretVersionsController) per non
  # ombreggiare il namespace ::Projects. Gate `secrets.manage`: il registro dice CHI ha letto CHE COSA,
  # ed è materiale per chi risponde dei segreti, non per chiunque li consumi.
  #
  # Distinto dalla pagina Attività del Vault (Member::Vault::AuditController, org-level, permesso
  # secrets_audit.view): quella unifica i tre schemi org-scoped su tutti i progetti visibili, questa
  # sta dentro il progetto e risponde alla domanda che si fa stando lì.
  class ProjectSecretEventsController < Member::BaseController
    include Member::SecretEnvironmentBoundary

    # CYRA-924 — a register sorts on the date only.
    SORT_COLUMNS = { "occurred_at" => :created_at }.freeze

    before_action :set_project
    before_action :require_secrets_manage

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :event_action, :environment_id, :actor_id, :from, :to, :q, only: :index

    def index
      scope = confined(@project.secret_events.includes(:actor, :environment))
      @counts = counts_for(scope)
      @pagination = paginate(sorted(filtered(scope).recent, columns: SORT_COLUMNS))
      @events = @pagination.records
      @environments = allowed_environments
      @actors = actors_for(scope)
      @stats = @project.ticket_tally
    end

    private

    # Anti-BOLA + scoping: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def require_secrets_manage
      require_permission!("secrets.manage", scope: @project)
    end

    # Confine ambienti dell'attore su questo progetto (CYRA-78): stessa policy della matrice. Il NOME
    # di un secret di production è già un'informazione su production, quindi le righe degli ambienti
    # fuori confine non entrano nemmeno nei conteggi. Gli eventi senza ambiente (bundle-level, sync)
    # restano visibili: non parlano di un ambiente in particolare.
    def confined(relation)
      return relation unless secret_access.restricted?

      relation.where(environment_id: [ nil ] + allowed_environments.map(&:id))
    end


    def allowed_environments
      @allowed_environments ||= @project.environments.ordered.to_a.select { |e| secret_access.allowed?(e.code) }
    end

    # I filtri della toolbar. `action` è riservato (nome dell'azione controller) → il filtro azione
    # viaggia come `event_action`, come sulla pagina Attività del Vault. L'attore è multi-valore:
    # «chi ha toccato questo vault» è quasi sempre una domanda su più persone insieme.
    def filtered(relation)
      relation = relation.where(action: params[:event_action]) if params[:event_action].present?
      relation = relation.where(environment_id: params[:environment_id]) if params[:environment_id].present?
      relation = relation.where(actor_id: filter_ids(:actor_id)) if filter_ids(:actor_id).any?
      relation = relation.where(created_at: time_bound(:from)..) if time_bound(:from)
      relation = relation.where(created_at: ..time_bound(:to)) if time_bound(:to)
      relation
    end

    # Chip del titolo: quante righe in tutto, quante sono accessi ai valori e quanti tentativi sono
    # stati fermati. Conteggi sul registro INTERO (non sui filtri): dicono cosa c'è da guardare, e un
    # filtro attivo non deve poterli far sembrare zero. Un solo group by, nessuna query per chip.
    def counts_for(scope)
      per_action = scope.group(:action).count
      { total: per_action.values.sum, read: per_action["read"].to_i, denied: per_action["denied"].to_i }
    end

    # Le persone che compaiono nel registro: il filtro attore offre solo chi ha davvero lasciato una
    # riga qui, invece dell'intera rubrica dell'organizzazione.
    def actors_for(scope)
      Accounts::Account.where(id: scope.distinct.pluck(:actor_id).compact).order(:email)
    end
  end
end
