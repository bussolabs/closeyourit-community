# frozen_string_literal: true

module Member
  module Workload
    # Board del carico di lavoro non-dev, team-scoped. Nessun require_permission!: l'autorizzazione è
    # l'appartenenza al team → lo scope visible.workload_actions è sia il confine di lettura
    # sia quello di scrittura (una action di un team altrui = 404 anti-BOLA). Model SEMPRE
    # ::Workload::Action fully-qualified (anti-shadowing sotto Member::Workload, vedi rules/naming.md).
    class ActionsController < Member::BaseController
      permission_not_required "Carico di lavoro del team: l'appartenenza al team è insieme il confine di lettura e " \
                              "quello di scrittura."

      # Whitelist ordinamento colonne della lista (contratto Sortable#sorted).
      SORT_COLUMNS = {
        "title" => "LOWER(workload_actions.title)",
        "status" => :status,
        "team" => { expr: "LOWER(teams_teams.name)", joins: :team },
        "scheduled" => :scheduled_at,
        "due" => :due_at,
        "created" => :created_at
      }.freeze

      before_action :set_action, only: %i[show edit update destroy status]
      before_action :require_team_membership, only: %i[new create]
      before_action :load_form_options, only: %i[new create edit update]

      # Board Kanban per status (enum) = vista di DEFAULT: 4 colonne fisse
      # (planned/in_progress/done/cancelled). La tabella filtrabile vive su #list ("list view").
      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :team_id, :participant_id, :has_ticket, :q, only: :index

      def index
        statuses = ::Workload::Action.statuses.keys
        # Filtri board (team/participant/has_ticket; status è l'asse colonne) + ricerca ILIKE,
        # applicati PRIMA del group_by: solo gli items delle colonne si riducono.
        scope = apply_action_filters(visible.workload_actions.includes(:team, :ticket, :participants))
        actions = like_search(scope).to_a
        by_status = actions.group_by(&:status)
        @columns = statuses.map { |status| [ status, by_status[status] || [] ] }
        # CYRA-359 — le chip sono le STESSE della vista a elenco (totale + una per stato): gli stessi
        # dati riassunti in due modi diversi facevano chiedere quale dei due fosse quello giusto.
        # Si contano dalle colonne già in memoria: nessuna query in più rispetto a prima.
        @board_total = @columns.sum { |_status, column_actions| column_actions.size }
        @status_counts = @columns.to_h { |status, column_actions| [ status, column_actions.size ] }
        # K11/K12 — with a search on, each column reads "found / total" and an empty one collapses.
        @column_totals = (scope.unscope(:includes).group(:status).count if search_q.present?)
      end

      # Tabella filtrabile/ordinabile/paginata ("list view"), raggiunta dal bottone nella board.
      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :team_id, :participant_id, :status, :has_ticket, :q, :sort, only: :list

      def list
        @pagination = filtered_actions
        @actions = @pagination.records
        @status_counts = status_counts
        @saved_views = saved_views_for("workload_actions")
      end

      def show
        # Activity-log generalizzato: blocco Audit (ultimo evento) + cronologia nel modale.
        @activity_events = @action.activity_events.chronological.includes(:actor, :true_actor).to_a
        @last_activity = @activity_events.last
      end

      def new
        @action = ::Workload::Action.new(team: visible.teams.first)
      end

      def create
        @action = ::Workload::Action.new(team: visible.teams.find_by(id: params[:team_id]))
        result = ::Workload::Actions::Save.call(action: @action, attributes: action_params,
                                                participant_ids: params[:participant_ids],
                                                actor: Current.account, true_actor: Current.true_account)
        if result.ok?
          redirect_to member_workload_action_path(result.value), notice: t("member.workload.actions.created")
        else
          @errors = @action.errors.to_hash
          render :new, status: :unprocessable_content
        end
      end

      def edit; end

      def update
        result = ::Workload::Actions::Save.call(action: @action, attributes: action_params,
                                                participant_ids: params[:participant_ids],
                                                actor: Current.account, true_actor: Current.true_account)
        if result.ok?
          redirect_to member_workload_action_path(@action), notice: t("member.workload.actions.updated")
        else
          @errors = @action.errors.to_hash
          render :edit, status: :unprocessable_content
        end
      end

      def destroy
        @action.destroy
        redirect_to member_workload_actions_path, notice: t("member.workload.actions.deleted")
      end

      # Cambio status dal drag della board. Enum validato a mano (un valore fuori enum solleverebbe
      # ArgumentError su update): status ignoto → 422 così il JS ricarica. Scoping via set_action
      # (404 anti-BOLA su team altrui). Non passa da Save per NON toccare i partecipanti.
      def status
        new_status = params[:status].to_s
        return head :unprocessable_content unless ::Workload::Action.statuses.key?(new_status)

        @action.update!(status: new_status)
        redirect_back fallback_location: member_workload_action_path(@action),
                      notice: t("member.workload.actions.status_changed")
      end

      private

      def set_action
        @action = visible.workload_actions.find(params[:id])
      end

      # Senza team non c'è board da gestire → torna all'index (vuoto) con avviso.
      def require_team_membership
        redirect_to member_workload_actions_path, alert: t("member.workload.actions.no_team") if visible.teams.none?
      end

      def filtered_actions
        scope = apply_action_filters(visible.workload_actions.includes(:team, :ticket, :participants).order(created_at: :desc))
        paginate(like_search(sorted(scope, columns: SORT_COLUMNS)))
      end

      # Filtri multi (param array) condivisi da list (#filtered_actions) e board (#index). Ogni
      # where scatta solo se il param è presente: la board non espone il chip status (l'asse
      # colonne) → param assente → where saltato.
      def apply_action_filters(scope)
        scope = scope.where(team_id: filter_ids(:team_id)) if filter_ids(:team_id).any?
        scope = scope.where(status: filter_ids(:status)) if filter_ids(:status).any?
        scope = filter_by_participant(scope)
        scope = filter_by_ticket(scope)
        scope
      end

      def filter_by_participant(scope)
        ids = filter_ids(:participant_id)
        return scope if ids.empty?

        scope.joins(:participations).where(connections_workload_participants: { account_id: ids }).distinct
      end

      def filter_by_ticket(scope)
        case params[:has_ticket]
        when "linked" then scope.where.not(ticket_id: nil)
        when "unlinked" then scope.where(ticket_id: nil)
        else scope
        end
      end

      def like_search(scope)
        return scope if search_q.blank?

        scope.where("workload_actions.title ILIKE ?", "%#{search_q}%")
      end

      # Totale per stato (chip nell'header) mappato sulle chiavi enum, zeri inclusi.
      # CYRA-359 — `group(:status).count` su un enum torna chiavi STRINGA ("in_progress"), non i valori
      # interi della mappa: cercandole per valore il conteggio era sempre nil, quindi le chip della
      # vista a elenco mostravano zero su tutto anche con la lista piena. Le chiavi si prendono dai
      # nomi degli stati, che sono anche l'ordine in cui vanno rese.
      def status_counts
        raw = visible.workload_actions.reorder(nil).group(:status).count
        ::Workload::Action.statuses.keys.index_with { |status| raw[status] || 0 }
      end

      def load_form_options
        @teams = visible.teams.order(:name)
        @statuses = ::Workload::Action.statuses.keys
        @linkable_tickets = linkable_tickets
        @candidate_participants = candidate_participants
      end

      # CYRA-364 — le poche voci iniziali del campo «Ticket collegato»: i ticket toccati di recente,
      # non più i 200 di tutta l'organizzazione. Chi cerca ne riceve altri dal server digitando.
      # Il ticket GIÀ collegato entra sempre nell'elenco: se sparisse dalle opzioni, il salvataggio
      # successivo del form cancellerebbe il collegamento senza che nessuno lo abbia chiesto.
      def linkable_tickets
        recent = ::Ticketing::LinkableTickets.call(scope: visible.tickets)
        ([ @action&.ticket ].compact + recent.to_a).uniq
      end

      # Membri dei team a cui appartiene l'account (candidati partecipanti). Il model valida che ogni
      # partecipante sia del team della action; il filtro dinamico per-team è follow-up.
      def candidate_participants
        ::Accounts::Account
          .where(id: ::Connections::TeamMembership.where(team_id: visible.teams.select(:id)).select(:account_id))
          .distinct.order(:name)
      end

      def action_params
        permitted = params.permit(:title, :description, :status, :scheduled_at, :due_at, :ticket_id)
        permitted[:ticket_id] = sanitized_ticket_id(permitted[:ticket_id]) if permitted.key?(:ticket_id)
        permitted
      end

      # Un ticket linkabile deve essere visibile all'utente (anti-BOLA: un id non visibile → nessun link).
      def sanitized_ticket_id(ticket_id)
        return nil if ticket_id.blank?

        visible.tickets.exists?(id: ticket_id) ? ticket_id : nil
      end
    end
  end
end
