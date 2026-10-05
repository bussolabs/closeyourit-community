# frozen_string_literal: true

module Member
  # CRUD dei team (gruppo-di-persone). Gated da `permissions.manage`. Un team riceve RUOLI + SCOPE
  # (progetti/gruppi) e ha MEMBRI; tutto riconciliato via i servizi Teams::Set*. Anti-BOLA all'org.
  class TeamsController < Member::BaseController
    # Whitelist ordinamento (contratto Sortable#sorted). La colonna Scope (progetti/gruppi
    # misti) resta statica: non ha un ordine SQL sensato.
    SORT_COLUMNS = {
      "team" => "LOWER(teams_teams.name)",
      "roles" => "(SELECT COUNT(*) FROM authorization_team_roles tr WHERE tr.team_id = teams_teams.id)",
      "members" => "(SELECT COUNT(*) FROM connections_team_memberships tm WHERE tm.team_id = teams_teams.id)"
    }.freeze

    before_action :require_manage
    before_action :require_actor_privileged!, only: %i[access_preview]

    # CYRA-728 — lo schema what-if ricalcola i permessi che il team AVREBBE e li disegna: nessuna
    # scrittura, ed è quello che si guarda PRIMA di salvare. È il salvataggio a chiedere conferma.
    confirmation_not_required "ricalcola e mostra i permessi pendenti, non ne salva nessuno",
                              only: :access_preview
    before_action :set_team, only: %i[edit update destroy access_preview]
    before_action :load_form_options, only: %i[new create edit update access_preview]

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :q, only: :index

    def index
      scope = Current.organization.teams.ordered
                                 .includes(:roles, :members, :scoped_projects, :scoped_groups)
      scope = scope.where("teams_teams.name ILIKE :q", q: "%#{search_q}%") if search_q.present?
      @pagination = paginate(sorted(scope, columns: SORT_COLUMNS))
      @teams = @pagination.records
      # CYRA-555 — il chip in testata dice quanti team esistono, non quanti ne ha lasciati passare
      # la ricerca (stessa regola dei chip di Ticket e Conoscenza): a zero corrispondenze il numero
      # e il messaggio devono raccontare la stessa cosa.
      @total_teams = Current.organization.teams.count
    end

    def new
      @team = Current.organization.teams.new
      @selected = empty_selection
    end

    def create
      @team = Current.organization.teams.new(team_params)
      @team.created_by = Current.account
      if @team.save
        result = sync_team
        if result.ok?
          redirect_to member_teams_path, notice: t("member.teams.created")
        else
          # Escalation bloccata (R403-ACCESS-001): niente ruoli/scope/membri applicati (short-circuit) →
          # rimuovo il team appena creato e rimando indietro con l'errore leggibile, mai un 500.
          @team.destroy
          @team = Current.organization.teams.new(team_params)
          @selected = submitted_selection
          flash.now[:alert] = result.error.message
          render :new, status: :forbidden
        end
      else
        @errors = @team.errors.to_hash
        @selected = submitted_selection
        render :new, status: :unprocessable_content
      end
    end

    def edit
      @selected = current_selection(@team)
      # Schema permessi effettivi per-membro (owner/god), sotto il form.
      return unless actor_privileged?

      @access_matrix = Authorization::PreviewAccess::Team.call(
        team: @team, projects: @projects, params: @selected
      )
    end

    # Schema what-if per-membro (owner/god): ricalcola i permessi effettivi di ogni membro coi params
    # PENDENTI del form (ruoli/scope/membri), zero persistenza. Vedi Authorization::PreviewAccess::Team.
    def access_preview
      diffs = Authorization::PreviewAccess::Team.call(
        team: @team, projects: @projects, params: team_access_preview_params
      )
      render partial: "member/shared/access_matrix", locals: { subjects: diffs }
    end

    def update
      if @team.update(team_params)
        result = sync_team
        if result.ok?
          redirect_to member_teams_path, notice: t("member.teams.updated")
        else
          # Escalation bloccata (R403-ACCESS-001): ruoli/scope/membri non toccati (short-circuit) →
          # rimando al form con l'errore leggibile. Il name/color eventualmente aggiornati restano.
          @selected = submitted_selection
          flash.now[:alert] = result.error.message
          render :edit, status: :forbidden
        end
      else
        @errors = @team.errors.to_hash
        @selected = submitted_selection
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @team.destroy
      redirect_to member_teams_path, notice: t("member.teams.deleted")
    end

    private

    # Anti-BOLA: id di un'altra org → RecordNotFound.
    def set_team
      @team = Current.organization.teams.find(params[:id])
    end

    def load_form_options
      @accounts = Current.organization.accounts.order(:name)
      @roles = Current.organization.roles.ordered
      @groups = Current.organization.groups.ordered
      @projects = Current.organization.projects.order(:name)
    end

    def team_params
      params.permit(:name, :color, :default_assignee_id)
    end

    # Escalation su più superfici → short-circuit al PRIMO guard che rifiuta (R403-ACCESS-001), senza
    # toccare le successive: ruoli (chiavi possedute) PRIMA, poi scope (visibilità dell'attore, CYRA-237),
    # infine i membri. Ogni Result è propagato (anche i membri: un errore non va ingoiato come falso ok).
    def sync_team
      actor = Current.account
      true_actor = Current.true_account
      roles_result = Teams::SetTeamRoles.call(team: @team, role_ids: params[:role_ids], actor: actor, true_actor: true_actor)
      return roles_result if roles_result.err?

      scope_result = Teams::SetTeamScope.call(team: @team, group_ids: params[:group_ids], project_ids: params[:project_ids],
                                              actor: actor, true_actor: true_actor)
      return scope_result if scope_result.err?

      Teams::SetTeamMembers.call(team: @team, account_ids: params[:member_ids], actor: actor, true_actor: true_actor)
    end

    def empty_selection
      { member_ids: [], role_ids: [], group_ids: [], project_ids: [] }
    end

    def submitted_selection
      { member_ids: Array(params[:member_ids]).reject(&:blank?),
        role_ids: Array(params[:role_ids]).reject(&:blank?),
        group_ids: Array(params[:group_ids]).reject(&:blank?),
        project_ids: Array(params[:project_ids]).reject(&:blank?) }
    end

    def current_selection(team)
      { member_ids: team.team_memberships.pluck(:account_id),
        role_ids: team.team_roles.pluck(:role_id),
        group_ids: team.group_accesses.pluck(:group_id),
        project_ids: team.project_accesses.pluck(:project_id) }
    end

    # Params pendenti dello schema what-if (identici al form del team).
    def team_access_preview_params
      { member_ids: params[:member_ids], role_ids: params[:role_ids],
        group_ids: params[:group_ids], project_ids: params[:project_ids] }
    end

    def require_manage
      require_permission!("permissions.manage")
    end
  end
end
