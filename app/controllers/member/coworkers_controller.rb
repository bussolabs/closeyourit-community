module Member
  class CoworkersController < BaseController
    before_action :require_prototype
    before_action :load_puckies
    before_action :load_puck, only: %i[show update]
    PAGE = 20
    permission_not_required "Local prototype: each account can access only its own Puckies in the current organization"

    def index
      @puck = @puckies.first
      load_conversation if @puck
      render :show
    end

    def show
      load_conversation
      render :older, layout: false if params[:before].present? && turbo_frame_request?
    end

    def create
      puck = Coworkers::Puck.new(params.require(:puck).permit(:name, :instructions).merge(organization: Current.organization, account: Current.account))
      apply_team(puck)
      Coworkers::Presets.apply(puck, params.dig(:puck, :preset))
      return head :forbidden if puck.team? && !puck.managed_by?(Current.account)

      puck.save!
      redirect_to member_coworker_path(puck)
    rescue ActiveRecord::RecordInvalid
      redirect_to member_coworkers_path, alert: t("member.coworkers.invalid")
    end

    def update
      return head :forbidden unless @puck.managed_by?(Current.account)
      raise ActiveRecord::StaleObjectError unless params.dig(:puck, :lock_version).to_s == @puck.lock_version.to_s
      @puck.update!(params.require(:puck).permit(:memory, :lock_version))
      redirect_to member_coworker_path(@puck, panel: "memory")
    rescue ActiveRecord::StaleObjectError
      redirect_to member_coworker_path(@puck, panel: "memory"), alert: t("member.coworkers.conflict")
    rescue ActiveRecord::RecordInvalid
      redirect_to member_coworker_path(@puck, panel: "memory"), alert: t("member.coworkers.invalid")
    end

    private

    def require_prototype
      head :not_found unless Coworkers.available_to?(account: Current.account, organization: Current.organization)
    end

    def load_puckies
      @puckies = visible.coworker_puckies.order(:created_at).to_a
      @latest_runs = Coworkers::Run.where(puck_id: @puckies.map(&:id)).select("DISTINCT ON (puck_id) coworkers_runs.*")
                                   .order(:puck_id, created_at: :desc).index_by(&:puck_id)
    end

    # The conversation opens on the last PAGE messages; older pages load in a frame above them.
    # One extra row tells whether there is more and which day the page before ends on.
    def load_conversation
      scope = @puck.runs.where(kind: %w[chat watch]).includes(:action_proposals, approved_task: [ { screen_attachment: :blob }, { video_attachment: :blob } ], child_runs: :puck).order(created_at: :desc)
      scope = scope.where(created_at: ...@puck.runs.find(params[:before]).created_at) if params[:before].present?
      rows = scope.limit(PAGE + 1).to_a
      @chats = rows.first(PAGE).reverse
      @previous_chat = rows[PAGE]
    end

    def load_puck
      @puck = visible.coworker_puckies.find(params[:id])
    end

    # A team Puck is bound to a project the creator can see (CYRA-1023).
    def apply_team(puck)
      return unless params.dig(:puck, :visibility) == "team"

      puck.visibility = "team"
      puck.project = visible.projects.find_by(id: params.dig(:puck, :project_id))
    end
  end
end
