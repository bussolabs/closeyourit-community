# frozen_string_literal: true

module Member
  # CRUD gruppi (macro-progetti) dell'organizzazione corrente. Lettura (index/show) per tutti i
  # membri; gestione (new/create/edit/update/destroy) per admin/owner. Un gruppo è un contenitore:
  # niente ticket/key propri. Scoping anti-BOLA all'org. Raggiunto dal bottone "Groups" in Projects.
  class GroupsController < Member::BaseController
    # Whitelist ordinamento (contratto Sortable#sorted).
    SORT_COLUMNS = {
      "group" => "LOWER(projects_groups.name)",
      "projects" => "(SELECT COUNT(*) FROM projects p WHERE p.group_id = projects_groups.id)"
    }.freeze

    before_action :require_view, only: %i[index show]
    before_action :require_management, only: %i[new create edit update destroy]
    before_action :set_group, only: %i[show edit update destroy]

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :q, :sort, only: :index

    def index
      # with_attached_icon_image: la lista renderizza l'icona (EntityMark) per gruppo →
      # senza preload un active_storage_attachments per riga (N+1 con 2+ gruppi).
      scope = visible.groups.with_attached_icon_image.ordered
      scope = scope.where("projects_groups.name ILIKE :q", q: "%#{search_q}%") if search_q.present?
      @pagination = paginate(sorted(scope, columns: SORT_COLUMNS))
      @groups = @pagination.records
      @project_counts = Projects::Project.where(group_id: @groups.map(&:id)).group(:group_id).count
      @saved_views = saved_views_for("groups")
    end

    # CYRA-362 — la pagina riassume i progetti che contiene (errori aperti, ticket non chiusi,
    # disponibilità 24h, ultimo rilascio). Scoping esplicito da visible.projects: chi vede il
    # gruppo vede già tutti i suoi progetti (Authorization::VisibleScope segue il gruppo), ma il
    # riassunto non deve poter sommare nulla che l'utente non possa aprire.
    def show
      @projects = visible.projects.where(group_id: @group.id)
                                          .with_attached_icon_image.order(:name).to_a
      @rollup = ::Projects::Groups::Rollup.new(@projects)
      # Gli status NON conclusi (da fare + in corso, quindi anche in revisione): il link della card
      # porta esattamente all'insieme che il numero conta, come nella pagina progetto (CYRA-358).
      @unresolved_status_ids = Current.organization.ticket_statuses
                                      .where.not(category: :done).ordered.pluck(:id)
    end

    def new
      @group = Current.organization.groups.new
    end

    def create
      @group = Current.organization.groups.new(group_params)
      @group.created_by = Current.account
      if @group.save && stacked_modal_request?
        render_modal_created(value: @group.id, label: @group.name, color: @group.color)
      elsif @group.persisted?
        redirect_to member_group_path(@group), notice: t("member.groups.created")
      else
        @errors = @group.errors.to_hash
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      if @group.update(group_params)
        redirect_to member_group_path(@group), notice: t("member.groups.updated")
      else
        @errors = @group.errors.to_hash
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      Projects::Groups::Destroy.call(group: @group)
      redirect_to member_groups_path, notice: t("member.groups.deleted")
    end

    private

    # Anti-BOLA: un id di un'altra org → RecordNotFound.
    def set_group
      @group = Current.organization.groups.find(params[:id])
    end

    def group_params
      params.permit(:name, :color, :icon, :icon_image)
    end

    # Lettura (index/show): gata da project_groups.view; chi gestisce (project_groups.manage) vede sempre.
    def require_view
      require_permission!("project_groups.view") unless can?("project_groups.manage")
    end

    def require_management
      require_permission!("project_groups.manage")
    end
  end
end
