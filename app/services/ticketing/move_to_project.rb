# frozen_string_literal: true

module Ticketing
  # CYRA-1352 — moves a ticket to another project of the same organization. It takes the next code there,
  # and Ticketing::TicketMove keeps the old code leading to it. Milestone and parent epic belong to the old
  # project and are dropped; work tied to the old project's repository or signals refuses the move.
  class MoveToProject < ApplicationService
    def initialize(ticket:, project:, actor:, true_actor: nil)
      @ticket = ticket
      @project = project
      @actor = actor
      @true_actor = true_actor
    end

    def call
      refusal = refusal_code
      return refuse(*refusal) if refusal

      from_project = @ticket.project
      from_code = @ticket.code
      ApplicationRecord.transaction do
        number = next_number!
        TicketMove.create!(organization: from_project.organization, ticket: @ticket, from_project:,
                           from_number: @ticket.number, to_project: @project, to_number: number, actor: @actor)
        @ticket.ticket_platforms.where.not(platform_id: @project.platform_ids).delete_all
        # project_id is read-only so no ordinary edit moves a ticket; this one stays in the organization,
        # so the history's organization_id stays true (the reason for the lock, see Ticketing::Ticket).
        Ticket.where(id: @ticket.id).update_all(project_id: @project.id, number:, milestone_id: nil, parent_id: nil,
                                                updated_at: Time.current)
        @ticket.reload
        RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor, action: "moved_to_project",
                            data: { from: from_code, to: @ticket.code,
                                    from_project_id: from_project.id, to_project_id: @project.id })
      end
      Result.ok(@ticket)
    end

    private

    def refusal_code
      return [ "R422-TICKET-025", :same_project ] if @project.id == @ticket.project_id
      return [ "R422-TICKET-026", :other_organization ] if @project.organization_id != @ticket.project.organization_id
      return [ "R409-TICKET-027", :machine_working ] if @ticket.agent_workflow && !@ticket.agent_workflow.terminal?
      return [ "R409-TICKET-028", :repository_work ] if @ticket.github_branches.exists? || @ticket.github_pull_requests.exists?
      return [ "R409-TICKET-029", :epic_with_children ] if @ticket.children.exists?
      return [ "R409-TICKET-030", :project_signal ] if @ticket.error_group || @ticket.metric_group

      nil
    end

    def refuse(code, reason)
      status = code.start_with?("R409") ? :conflict : :unprocessable_content
      Result.err(AppError.new(I18n.t("member.tickets.move.errors.#{reason}"), code:, status:))
    end

    # The same counter a new ticket takes its number from (Ticket#assign_number), under the same lock.
    def next_number!
      target = Projects::Project.lock.find(@project.id)
      number = target.last_ticket_number + 1
      target.update_column(:last_ticket_number, number)
      number
    end
  end
end
