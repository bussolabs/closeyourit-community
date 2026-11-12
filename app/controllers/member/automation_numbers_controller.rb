# frozen_string_literal: true

module Member
  # CYRA-1296 — the numbers of the automatic round: one table, a row per visible project, the last 30 days.
  # Read-only. It is the baseline every gate of the round is judged against: a gate that stops more
  # without lowering the failures is a cost, not a gain.
  class AutomationNumbersController < Member::BaseController
    WINDOW = 30.days
    # Sortable#sorted_rows contract: key → reader of the value; a project without the number goes last.
    SORT_COLUMNS = {
      "project" => ->(row) { row.project.name.downcase },
      "completed" => ->(row) { row.numbers.completed },
      "hands_off" => ->(row) { row.numbers.hands_off_rate },
      "first_pass" => ->(row) { row.numbers.first_pass_rate },
      "attempts" => ->(row) { row.numbers.attempts_per_ticket },
      "plans" => ->(row) { row.numbers.plans_approved_rate },
      "lead" => ->(row) { row.numbers.lead_hours },
      "cost" => ->(row) { row.numbers.cost_per_ticket },
      "failures" => ->(row) { row.numbers.failures_per_hundred }
    }.freeze

    Row = Data.define(:project, :numbers)

    before_action :require_view

    remembers_filters :q, :sort, only: :index

    def index
      projects = visible.projects.reorder(:name)
      @any_project = projects.exists?
      projects = projects.where("projects.name ILIKE ?", "%#{::Projects::Project.sanitize_sql_like(search_q)}%") if search_q.present?
      projects = projects.to_a
      numbers = ::Agents::Numbers::PerProject.call(project_ids: projects.map(&:id), since: WINDOW.ago)
      rows = projects.map { |project| Row.new(project:, numbers: numbers.fetch(project.id)) }
      @completed = rows.sum { |row| row.numbers.completed }
      @pagination = Pagination.from_array(sorted_rows(rows, columns: SORT_COLUMNS), page: params[:page], per: requested_per(Pagination::DEFAULT_PER))
      @rows = @pagination.records
    end

    private

    def require_view
      return if can_view_agents?

      require_permission!("agents.view")
    end
  end
end
