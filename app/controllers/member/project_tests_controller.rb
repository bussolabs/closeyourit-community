# frozen_string_literal: true

module Member
  # Tests tab of a project (CYRA-1165): the tests the CI reported, filtered by flaky, failing and
  # known, and the history of one test run by run with version and commit. Reading follows project
  # visibility, like Usage; marking a known failure is Member::ProjectTestKnownFailuresController.
  # Flat controller (like ProjectUsageController) so it does not shadow the ::Projects namespace.
  class ProjectTestsController < Member::BaseController
    permission_not_required "The outcome of a project's tests is product material, not a secret: it says which " \
                            "test passed or failed and on which commit, never who wrote it. Same boundary as " \
                            "the Usage tab, where the gate is the visibility of the project."

    FILTERS = %w[flaky failing known].freeze

    before_action :set_project
    before_action :set_header_data

    def index
      scope = @project.test_cases
      @counts = counts_for(scope)
      @filter = params[:filter].presence_in(FILTERS)
      @pagination = paginate(filtered(scope).recent_first.includes(:known_failure))
      @test_cases = @pagination.records
      @last_run = @project.test_runs.recent_first.first
    end

    def show
      @test_case = @project.test_cases.find(params[:id])
      @known_failure = @test_case.known_failure
      @pagination = paginate(@test_case.results.joins(:test_run).includes(:test_run)
                                       .order("projects_test_runs.ran_at DESC"))
      @results = @pagination.records
      @can_edit = can?("projects.edit", scope: @project)
    end

    private

    # Anti-BOLA + scoping: a project out of sight (another org, not assigned) is a RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def set_header_data
      @stats = @project.ticket_tally
    end

    def filtered(scope)
      case @filter
      when "flaky" then scope.flaky
      when "failing" then scope.failing
      when "known" then scope.with_known_failure
      else scope
      end
    end

    # Counts on the whole project, not on the filter: they say what there is to look at. One query
    # for the three columns, one for the known failures.
    def counts_for(scope)
      total, flaky, failing = scope.pick(Arel.sql("COUNT(*)"),
                                         Arel.sql("COUNT(*) FILTER (WHERE flaky_at IS NOT NULL)"),
                                         Arel.sql("COUNT(*) FILTER (WHERE last_status = 'failed')"))
      { total: total.to_i, flaky: flaky.to_i, failing: failing.to_i, known: scope.with_known_failure.count }
    end
  end
end
