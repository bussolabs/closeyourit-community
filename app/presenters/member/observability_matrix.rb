# frozen_string_literal: true

module Member
  # CYRA-927 — the Observability landing as one table: a row per visible project, a column per signal.
  # Every column is ONE query grouped by project over all visible projects, so the cost does not grow
  # with the rows, and the all-projects row sums the same numbers. A signal never set up on a project
  # is an `:off` cell that leads to setting it up; one the project cannot have is `:na`.
  class ObservabilityMatrix < ProjectMatrix
    COLUMNS = %i[errors vulnerabilities replays logs performance].freeze
    TREND_HOURS = 24

    def i18n_scope = "member.overviews.observability"

    # Recordings exist only on web projects: the column shows once a project can record, so the ones
    # that have not turned it on still see where to do it.
    def columns = replay_capable.any? ? COLUMNS : COLUMNS - [ :replays ]

    # The projects with the most errors to resolve first: that is where to look.
    def projects_scope
      unresolved = ::Errors::Group.status_unresolved
                                  .where(::Errors::Group.arel_table[:project_id].eq(::Projects::Project.arel_table[:id]))
                                  .select(Arel.star.count)
      @visible_projects.with_attached_icon_image.reorder(Arel.sql("(#{unresolved.to_sql}) DESC"), :name)
    end

    def total_cells
      trend = hours.map { |hour| error_events.sum { |(_, at), count| at.to_i == hour.to_i ? count : 0 } }
      {
        errors: count_cell(:errors, unresolved_errors.values.sum, routes.member_monitoring_error_groups_path(ft: 1, status: [ "unresolved" ]),
                           alert: true, trend:, rising: rising?(error_events)),
        vulnerabilities: count_cell(:vulnerabilities, open_findings.values.sum, routes.member_monitoring_vulnerabilities_path),
        replays: count_cell(:replays, replay_sessions.values.sum, routes.member_monitoring_replays_path),
        logs: count_cell(:logs, recent_logs.values.sum, routes.member_monitoring_log_entries_path),
        performance: count_cell(:performance, metric_groups.values.sum, routes.member_monitoring_metric_groups_path)
      }
    end

    def project_cells(project)
      id = project.id
      filter = { project_id: [ id ] }
      events = error_events.select { |(project_id, _), _| project_id == id }
      {
        errors: count_cell(:errors, unresolved_errors[id], routes.member_monitoring_error_groups_path(filter.merge(ft: 1, status: [ "unresolved" ])),
                           alert: true, trend: hours.map { |hour| events.sum { |(_, at), count| at.to_i == hour.to_i ? count : 0 } },
                           rising: rising?(events)),
        vulnerabilities: count_cell(:vulnerabilities, open_findings[id], routes.member_monitoring_vulnerabilities_path(filter)),
        replays: replays_cell(id, filter),
        logs: if @logs_ever.include?(id)
                count_cell(:logs, recent_logs[id], routes.member_monitoring_log_entries_path(filter))
              else
                off_cell(:logs, routes.member_monitoring_log_entries_path)
              end,
        performance: if metric_groups[id].to_i.positive?
                       count_cell(:performance, metric_groups[id], routes.member_monitoring_metric_groups_path(filter))
                     else
                       off_cell(:performance, routes.member_monitoring_metric_groups_path)
                     end
      }
    end

    private

    def prepare(projects) = @logs_ever = projects_with_logs(projects.map(&:id))

    def replays_cell(id, filter)
      return na_cell(:replays) unless replay_capable.include?(id)
      return off_cell(:replays, routes.member_monitoring_replays_path) unless replay_collecting.include?(id)

      count_cell(:replays, replay_sessions[id], routes.member_monitoring_replays_path(filter))
    end

    # More errors received in the last 24 hours than in the 24 before.
    def rising?(events)
      since = hours.first
      recent, before = events.partition { |(_, at), _| at >= since }
      recent.sum(&:last) > before.sum(&:last)
    end

    def hours
      @hours ||= begin
        current = Time.current.beginning_of_hour
        (0...TREND_HOURS).map { |index| current - (TREND_HOURS - 1 - index).hours }
      end
    end

    def unresolved_errors
      @unresolved_errors ||= ::Errors::Group.where(project_id: project_ids).status_unresolved.group(:project_id).count
    end

    # { [project_id, hour] => events } over two days: the last one draws the trend, both say if it grows.
    def error_events
      @error_events ||= ::Errors::Event.where(project_id: project_ids, created_at: (hours.first - TREND_HOURS.hours)..)
                                       .group(:project_id, Arel.sql("date_trunc('hour', errors_events.created_at)")).count
    end

    def open_findings
      @open_findings ||= ::Vulnerabilities::Finding.where(project_id: project_ids).status_open.group(:project_id).count
    end

    def replay_sessions
      @replay_sessions ||= ::Replays::Session.where(project_id: project_ids).group(:project_id).count
    end

    def replay_capable = @replay_capable ||= @visible_projects.session_replay_capable.pluck(:id).to_set

    def replay_collecting = @replay_collecting ||= @visible_projects.session_replay_collecting.pluck(:id).to_set

    def recent_logs
      @recent_logs ||= ::Logs::Entry.where(project_id: project_ids, created_at: 24.hours.ago..).group(:project_id).count
    end

    # A quiet day is not a signal to set up: only a project that never wrote a line is.
    def projects_with_logs(ids)
      written = ::Logs::Entry.where(::Logs::Entry.arel_table[:project_id].eq(::Projects::Project.arel_table[:id])).arel.exists
      ::Projects::Project.where(id: ids).where(written).pluck(:id).to_set
    end

    def metric_groups
      @metric_groups ||= ::Metrics::Group.where(project_id: project_ids).group(:project_id).count
    end
  end
end
