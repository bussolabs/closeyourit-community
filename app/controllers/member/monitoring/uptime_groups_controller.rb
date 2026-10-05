# frozen_string_literal: true

module Member
  module Monitoring
    # CRUD dei gruppi di monitor uptime (contenitori ORG-LEVEL). Lettura (index/show) gated
    # uptime_groups.view; gestione (new/create/edit/update/destroy) gated uptime_groups.manage
    # (manage-implies-view). Scoping anti-BOLA all'org (visible.uptime_groups). Raggiunto dal
    # bottone "Groups" nell'header della pagina Uptime. Distinto dal grouping DEGLI incident
    # (Member::Monitoring::Incidents::GroupsController), che è cosa diversa.
    class UptimeGroupsController < Member::BaseController
      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
      include Indexable

      # Whitelist ordinamento (contratto Sortable#sorted).
      SORT_COLUMNS = {
        "group" => "LOWER(uptime_groups.name)",
        "monitors" => "(SELECT COUNT(*) FROM uptime_monitors m WHERE m.group_id = uptime_groups.id)"
      }.freeze

      before_action :require_view, only: %i[index show]
      before_action :require_management, only: %i[new create edit update destroy publish unpublish]
      before_action :set_group, only: %i[show edit update destroy publish unpublish]

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :q, :sort, only: :index

      def index
        # with_attached_icon_image: la lista renderizza l'icona (EntityMark) per gruppo → preload
        # (senza, un active_storage_attachments per riga = N+1 con 2+ gruppi).
        scope = visible.uptime_groups.with_attached_icon_image.ordered
        scope = filter_by_search(scope, "uptime_groups.name")
        @groups = paginated(scope, columns: SORT_COLUMNS)
        @monitor_counts = Uptime::Monitor.where(group_id: @groups.map(&:id)).group(:group_id).count
        @saved_views = saved_views_for("uptime_groups")
      end

      def show
        @tab = params[:tab] == "public" ? "public" : "overview"
        # Anti-leak: solo i monitor del gruppo che il membro può vedere (intersezione con la visibilità).
        @monitors = visible.monitors.where(group_id: @group.id)
                                            .includes(:project, :environment).order(:name).to_a
      end

      def new
        @group = Current.organization.uptime_groups.new
      end

      def create
        @group = Current.organization.uptime_groups.new(group_params)
        @group.created_by = Current.account
        if @group.save
          redirect_to member_monitoring_uptime_group_path(@group), notice: t("member.uptime_groups.created")
        else
          @errors = @group.errors.to_hash
          render :new, status: :unprocessable_content
        end
      end

      def edit; end

      def update
        if @group.update(group_params)
          redirect_to member_monitoring_uptime_group_path(@group), notice: t("member.uptime_groups.updated")
        else
          @errors = @group.errors.to_hash
          render :edit, status: :unprocessable_content
        end
      end

      def destroy
        @group.destroy
        redirect_to member_monitoring_uptime_groups_path, notice: t("member.uptime_groups.deleted")
      end

      # Status page pubblica del gruppo (opt-in): attiva/disattiva il flag public_status_enabled.
      def publish   = toggle_public(true, :published)
      def unpublish = toggle_public(false, :unpublished)

      private

      # update_column (non update!): il flag pubblico è una preferenza indipendente, non deve essere
      # bloccato da validazioni estranee del gruppo. Stesso pattern del toggle publish del monitor.
      def toggle_public(enabled, key)
        @group.update_column(:public_status_enabled, enabled)
        redirect_to member_monitoring_uptime_group_path(@group, tab: "public"), notice: t("member.uptime_groups.#{key}")
      end

      # Anti-BOLA: un id di un'altra org (o senza permesso view) → RecordNotFound.
      def set_group
        @group = visible.uptime_groups.find(params[:id])
      end

      def group_params
        params.permit(:name, :color, :icon, :icon_image, :description)
      end

      # Lettura (index/show): gata da uptime_groups.view; chi gestisce (uptime_groups.manage) vede sempre.
      def require_view
        require_permission!("uptime_groups.view") unless can?("uptime_groups.manage")
      end

      def require_management
        require_permission!("uptime_groups.manage")
      end
    end
  end
end
