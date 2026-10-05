# frozen_string_literal: true

module Projects
  # Health shown on each card of the projects list: open errors, availability and last release.
  # One query per domain for the whole list, never one per card (CYRA-883).
  class CardHealth
    def initialize(projects)
      @project_ids = Array(projects).map(&:id)
    end

    def errors_for(project) = errors_by_project[project.id].to_i

    # :down if any monitor is down, :up only if every monitor is up, else :unknown — a stale
    # result counts as :unknown (Uptime::Monitor#display_status). nil without active monitors.
    def uptime_for(project)
      statuses = monitors_by_project[project.id]
      return nil if statuses.blank?
      return :down if statuses.include?(:down)

      statuses.all?(:up) ? :up : :unknown
    end

    # Same "last release" as the group page (Projects::Groups::Rollup#last_release).
    def release_for(project) = releases_by_project[project.id]

    private

    def errors_by_project
      @errors_by_project ||= query_or({}) do
        Errors::Group.where(project_id: @project_ids).status_unresolved.group(:project_id).count
      end
    end

    def monitors_by_project
      @monitors_by_project ||= query_or({}) do
        now = Time.current
        Uptime::Monitor.active.where(project_id: @project_ids)
                       .select(:id, :project_id, :active, :current_status, :last_checked_at, :interval_seconds)
                       .group_by(&:project_id)
                       .transform_values { |monitors| monitors.map { |monitor| monitor.display_status(now) } }
      end
    end

    def releases_by_project
      @releases_by_project ||= query_or({}) do
        ::Projects::Release.where(project_id: @project_ids)
                           .select("DISTINCT ON (project_id) projects_releases.*")
                           .order(:project_id, created_at: :desc)
                           .index_by(&:project_id)
      end
    end

    def query_or(empty) = @project_ids.empty? ? empty : yield
  end
end
