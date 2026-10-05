# frozen_string_literal: true

module Member
  # CYRA-930 — the Product landing: per project, the tickets still open, the ones being worked on,
  # the late ones, the ones nobody holds, and the ideas waiting for a vote. The late ones first.
  class ProductMatrix < ProjectMatrix
    COLUMNS = %i[open in_progress overdue unassigned ideas].freeze

    def i18n_scope = "member.overviews.product"

    def columns = COLUMNS

    def projects_scope
      late = ::Ticketing::Ticket.joins(:status).where.not(types_ticket_statuses: { category: :done })
                                .where(due_at: ...Time.current)
                                .where(::Ticketing::Ticket.arel_table[:project_id].eq(::Projects::Project.arel_table[:id]))
                                .select(Arel.star.count)
      @visible_projects.with_attached_icon_image.reorder(Arel.sql("(#{late.to_sql}) DESC"), :name)
    end

    def project_cells(project) = cells(project.id) { |path| path.call(project_id: [ project.id ]) }

    def total_cells = cells(nil) { |path| path.call }

    private

    def cells(id)
      pick = ->(counts) { id ? counts[id] : counts.values.sum }
      tickets = ->(filter) { yield(->(**scope) { routes.list_member_tickets_path(scope.merge(ft: 1).merge(filter)) }) }
      {
        open: count_cell(:open, pick.(open_tickets), tickets.call(status_id: open_statuses)),
        in_progress: count_cell(:in_progress, pick.(in_progress), tickets.call(status_id: working_statuses)),
        overdue: count_cell(:overdue, pick.(overdue), tickets.call(status_id: open_statuses, overdue: "1"), alert: true),
        unassigned: count_cell(:unassigned, pick.(unassigned), tickets.call(status_id: open_statuses, unassigned: "1")),
        ideas: count_cell(:ideas, pick.(open_ideas), yield(routes.method(:member_ideas_path)))
      }
    end

    def not_done
      ::Ticketing::Ticket.where(project_id: project_ids).joins(:status)
                         .where.not(types_ticket_statuses: { category: :done })
    end

    def open_statuses = @open_statuses ||= @organization.ticket_statuses.where.not(category: :done).ids

    def working_statuses = @working_statuses ||= @organization.ticket_statuses.where(category: :in_progress).ids

    def open_tickets = @open_tickets ||= not_done.group(:project_id).count

    def in_progress
      @in_progress ||= not_done.where(types_ticket_statuses: { category: :in_progress }).group(:project_id).count
    end

    def overdue = @overdue ||= not_done.where(due_at: ...Time.current).group(:project_id).count

    def unassigned = @unassigned ||= not_done.where(assignee_id: nil).group(:project_id).count

    def open_ideas = @open_ideas ||= ::Ideas::Idea.where(project_id: project_ids).status_open.group(:project_id).count
  end
end
