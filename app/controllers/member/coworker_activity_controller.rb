module Member
  # Every run of the Puckies this person can see, in one table (CYRA-1026).
  class CoworkerActivityController < BaseController
    include CoworkerScoped
    include Listable
    permission_not_required "Lists only runs of Puckies the viewer can already open (CYRA-1026)"

    SORT_COLUMNS = { "created" => :created_at, "puck" => "coworkers_puckies.name", "kind" => :kind,
                     "status" => :status, "tokens" => :tokens_used }.freeze
    KINDS = %w[chat task watch].freeze
    STATUSES = %w[queued running completed failed stopped interrupted].freeze

    def index
      @puckies = visible.coworker_puckies.order(:name).to_a
      @pagination = paginate(sorted(filtered, columns: SORT_COLUMNS))
      @runs = @pagination.records
      @pending = Assistant::Proposal.where(coworkers_run_id: @runs.map(&:id), account_id: Current.account.id)
                                    .status_pending.group(:coworkers_run_id).count
    end

    private

    def filtered
      scope = Coworkers::Run.joins(:puck).where(puck_id: @puckies.map(&:id)).includes(:puck, :account)
                            .order(created_at: :desc, id: :desc)
      scope = scope.where(status: filter_ids(:status) & STATUSES) if filter_ids(:status).any?
      scope = scope.where(kind: filter_ids(:kind) & KINDS) if filter_ids(:kind).any?
      scope = scope.where(puck_id: filter_ids(:puck_id)) if filter_ids(:puck_id).any?
      scope = scope.where("coworkers_runs.input ILIKE ?", "%#{ApplicationRecord.sanitize_sql_like(search_q)}%") if search_q.present?
      scope
    end
  end
end
