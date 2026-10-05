# frozen_string_literal: true

module Member
  # CRUD piattaforme (Types::Platform) dell'org corrente. Lettura per tutti i membri;
  # gestione (new/create/edit/update/destroy) per admin/owner. Scoping anti-BOLA all'org.
  class PlatformsController < Member::BaseController
    # Whitelist ordinamento (contratto Sortable#sorted).
    SORT_COLUMNS = {
      "platform" => "LOWER(types_platforms.label)",
      "code" => :code,
      "status" => :active,
      "uptime" => :supports_uptime,
      "projects" => "(SELECT COUNT(*) FROM connections_project_platforms pp " \
                    "WHERE pp.platform_id = types_platforms.id)"
    }.freeze

    before_action :require_view, only: %i[index]
    before_action :require_management, only: %i[new create edit update destroy]
    before_action :set_platform, only: %i[edit update destroy]

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :status, :q, :sort, only: :index

    def index
      scope = Current.organization.platforms
      scope = scope.where(active: filter_ids(:status).map { |v| v == "true" }) if filter_ids(:status).any?
      scope = scope.where("types_platforms.label ILIKE :q OR types_platforms.code ILIKE :q", q: "%#{search_q}%") if search_q.present?
      @pagination = paginate(sorted(scope.ordered, columns: SORT_COLUMNS))
      @platforms = @pagination.records
      @project_counts = Connections::ProjectPlatform
                        .where(platform_id: @platforms.map(&:id))
                        .group(:platform_id).count
      @saved_views = saved_views_for("platforms")
    end

    def new
      @platform = Current.organization.platforms.new(active: true, color: "indigo")
    end

    def create
      @platform = Current.organization.platforms.new(platform_params)
      @platform.created_by = Current.account
      if @platform.save
        redirect_to member_platforms_path, notice: t("member.platforms.created")
      else
        @errors = @platform.errors.to_hash
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      if @platform.update(platform_params)
        redirect_to member_platforms_path, notice: t("member.platforms.updated")
      else
        @errors = @platform.errors.to_hash
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      if @platform.destroy
        redirect_to member_platforms_path, notice: t("member.platforms.deleted")
      else
        redirect_to member_platforms_path, alert: t("member.platforms.delete_blocked")
      end
    end

    private

    # Anti-BOLA: un id di un'altra org → RecordNotFound.
    def set_platform
      @platform = Current.organization.platforms.find(params[:id])
    end

    def platform_params
      params.permit(:code, :label, :color, :position, :active, :supports_uptime)
    end

    # Lettura lista: gata da platforms.view; chi gestisce (platforms.manage) vede sempre.
    def require_view
      require_permission!("platforms.view") unless can?("platforms.manage")
    end

    def require_management
      require_permission!("platforms.manage")
    end
  end
end
