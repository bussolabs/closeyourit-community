# frozen_string_literal: true

module Member
  # CRUD environment (Types::Environment) dell'org corrente. Lettura per tutti i membri;
  # gestione (new/create/edit/update/destroy) per admin/owner. Scoping anti-BOLA all'org.
  class EnvironmentsController < Member::BaseController
    # Whitelist ordinamento (contratto Sortable#sorted).
    SORT_COLUMNS = {
      "environment" => "LOWER(types_environments.label)",
      "code" => :code,
      "status" => :active,
      "projects" => "(SELECT COUNT(*) FROM connections_project_environments pe " \
                    "WHERE pe.environment_id = types_environments.id)"
    }.freeze

    before_action :require_view, only: %i[index]
    before_action :require_management, only: %i[new create edit update destroy]
    before_action :set_environment, only: %i[edit update destroy]

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :status, :q, :sort, only: :index

    def index
      scope = Current.organization.environments
      scope = scope.where(active: filter_ids(:status).map { |v| v == "true" }) if filter_ids(:status).any?
      scope = scope.where("types_environments.label ILIKE :q OR types_environments.code ILIKE :q", q: "%#{search_q}%") if search_q.present?
      @pagination = paginate(sorted(scope.ordered, columns: SORT_COLUMNS))
      @environments = @pagination.records
      @project_counts = Connections::ProjectEnvironment
                        .where(environment_id: @environments.map(&:id))
                        .group(:environment_id).count
      @saved_views = saved_views_for("environments")
    end

    def new
      @environment = Current.organization.environments.new(active: true, color: "indigo")
    end

    def create
      @environment = Current.organization.environments.new(environment_params)
      @environment.created_by = Current.account
      if @environment.save
        redirect_to member_environments_path, notice: t("member.environments.created")
      else
        @errors = @environment.errors.to_hash
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      if @environment.update(environment_params)
        redirect_to member_environments_path, notice: t("member.environments.updated")
      else
        @errors = @environment.errors.to_hash
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      if @environment.destroy
        redirect_to member_environments_path, notice: t("member.environments.deleted")
      else
        redirect_to member_environments_path, alert: t("member.environments.delete_blocked")
      end
    end

    private

    # Anti-BOLA: un id di un'altra org → RecordNotFound.
    def set_environment
      @environment = Current.organization.environments.find(params[:id])
    end

    def environment_params
      params.permit(:code, :label, :color, :position, :active, :servers_enabled, :uptime_enabled, :secrets_enabled)
    end

    # Lettura lista: gata da environments.view; chi gestisce (environments.manage) vede sempre.
    def require_view
      require_permission!("environments.view") unless can?("environments.manage")
    end

    def require_management
      require_permission!("environments.manage")
    end
  end
end
