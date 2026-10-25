# frozen_string_literal: true

module Member
  # Products › Dashboard: one card per connected service, with its first numbers (D19–D25), and one page per service.
  # Flat controller so it does not shadow ::Dashboards. CYRA-1112
  class DashboardFeedsController < Member::BaseController
    permission_not_required "Visible to whoever sees the project: read only; connecting lives in the project settings.",
                            only: %i[index show]

    CARD_STEP = 12
    SETUP_LIMIT = 6
    PRELOAD = { project: [ { icon_image_attachment: :blob }, { group: { icon_image_attachment: :blob } } ] }.freeze
    STATES = %w[ok failed].freeze

    def index
      @cards_grouped = params[:grouped] != "none"
      @card_limit = [ params[:limit].to_i, CARD_STEP ].max
      @feeds_total = visible.dashboard_feeds.count
      feeds = filtered(visible.dashboard_feeds.left_joins(project: :group))
                .includes(PRELOAD).order(*card_order).limit(@card_limit + 1).to_a
      @more_cards = feeds.size > @card_limit
      @feeds = feeds.first(@card_limit)
      @setup_projects = filtering? ? [] : setup_projects
    end

    def show
      @feed = visible.dashboard_feeds.includes(project: { icon_image_attachment: :blob }).find(params[:id])
      @report = ::Dashboards::ReportView.new(@feed)
      @can_edit = can?("projects.edit", scope: @feed.project)
    end

    private

    def filtered(scope)
      scope = scope.where("projects.name ILIKE ?", "%#{Projects::Project.sanitize_sql_like(search_q)}%") if search_q.present?
      case params[:state]
      when "ok" then scope.where(last_error: nil).where.not(payload: nil)
      when "failed" then scope.where.not(last_error: nil)
      else scope
      end
    end

    # Grouped cards come group by group, so "Show more" never cuts a group in the middle of the page.
    def card_order
      by_name = Arel.sql("LOWER(projects.name)")
      @cards_grouped ? [ Arel.sql("LOWER(projects_groups.name) ASC NULLS LAST"), by_name ] : [ by_name ]
    end

    def filtering? = search_q.present? || STATES.include?(params[:state])

    # The visible projects without a service yet, only those the viewer may connect (D11).
    def setup_projects
      visible.projects.where.missing(:dashboard_feed).with_attached_icon_image.order(created_at: :desc)
             .select { |project| can?("projects.edit", scope: project) }.first(SETUP_LIMIT)
    end
  end
end
