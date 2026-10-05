# frozen_string_literal: true

module Member
  # CYRA-930 — the Automation landing: per project, the decisions waiting for the viewer (the same
  # queue as the Approvals page), the automations still open on its tickets, the stuck ones, and the
  # datasets. The machines belong to the organization: they stay on the Agents page.
  class AutomationMatrix < ProjectMatrix
    COLUMNS = %i[decisions active blocked datasets].freeze
    # The queue reads at most this many rows per source: the per-project split stays exact below it.
    QUEUE_LIMIT = 1000

    def i18n_scope = "member.overviews.automation"

    def columns = @visible_paths.include?(routes.member_datasets_path) ? COLUMNS : COLUMNS - [ :datasets ]

    # F122 — J4: the projects with a blocked automation first, like every other area opens on what is
    # not working; then by name.
    def projects_scope
      stuck = ::Agents::Workflow.joins(:ticket).where(completed_at: nil, cancelled_at: nil).where.not(blocked_at: nil)
                                .where(::Ticketing::Ticket.arel_table[:project_id].eq(::Projects::Project.arel_table[:id]))
                                .select(Arel.star.count)
      @visible_projects.with_attached_icon_image.reorder(Arel.sql("(#{stuck.to_sql}) DESC"), :name)
    end

    def project_cells(project)
      id = project.id
      tickets = ->(state) { routes.list_member_tickets_path(ft: 1, project_id: [ id ], workflow: state) }
      {
        decisions: count_cell(:decisions, decisions[project.key], routes.member_home_approvals_path(project: project.key),
                              alert: true),
        active: count_cell(:active, active[id], tickets.call("active")),
        blocked: count_cell(:blocked, blocked[id], tickets.call("blocked"), alert: true),
        datasets: if datasets[id].to_i.positive?
                    count_cell(:datasets, datasets[id], routes.member_datasets_path(project_id: [ id ]))
                  else
                    off_cell(:datasets, routes.member_datasets_path)
                  end
      }
    end

    def total_cells
      {
        decisions: count_cell(:decisions, queue.total, routes.member_home_approvals_path, alert: true),
        active: count_cell(:active, active.values.sum, routes.list_member_tickets_path(ft: 1, workflow: "active")),
        blocked: count_cell(:blocked, blocked.values.sum, routes.list_member_tickets_path(ft: 1, workflow: "blocked"), alert: true),
        datasets: count_cell(:datasets, datasets.values.sum, routes.member_datasets_path)
      }
    end

    private

    def queue
      @queue ||= ::Home::Approvals::Queue.call(
        account: @account, organization: @organization, visible_projects: @visible_projects,
        visible_tickets: ::Ticketing::Ticket.where(project_id: project_ids), limit: QUEUE_LIMIT
      )
    end

    # Keyed by project key: that is what a queue row carries.
    def decisions = @decisions ||= queue.items.map { |item| item.project&.key }.compact.tally

    def open_workflows
      ::Agents::Workflow.joins(:ticket).where(ticketing_tickets: { project_id: project_ids })
                        .where(completed_at: nil, cancelled_at: nil)
    end

    def active = @active ||= open_workflows.group("ticketing_tickets.project_id").count

    def blocked = @blocked ||= open_workflows.where.not(blocked_at: nil).group("ticketing_tickets.project_id").count

    def datasets = @datasets ||= ::Datasets::Dataset.where(project_id: project_ids).group(:project_id).count
  end
end
