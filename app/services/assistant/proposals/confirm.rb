# frozen_string_literal: true

module Assistant
  module Proposals
    # Runs a proposal the user confirmed: claims it atomically, re-checks visibility and permission
    # now, then calls the existing domain service (CYRA-907).
    class Confirm < ApplicationService
      def initialize(proposal:, account:, organization:, true_actor: nil)
        @proposal = proposal
        @account = account
        @organization = organization
        @true_actor = true_actor
      end

      def call
        return err("R409-PROPOSAL-001", :not_confirmable) unless claim

        result = run
        finish(result)
        result.ok? ? Result.ok(@proposal) : result
      end

      private

      # The UPDATE is the lock: only one request moves the row out of pending/failed.
      def claim
        Assistant::Proposal.where(id: @proposal.id, account_id: @account.id, organization_id: @organization.id,
                                  status: %i[pending failed]).update_all(status: :running, updated_at: Time.current) == 1
      end

      def run
        case @proposal.kind
        when "create_ticket" then create_ticket
        when "comment_ticket" then with_ticket(nil) { |t| Ticketing::AddComment.call(ticket: t, author: @account, params: { body: payload["body"] }) }
        when "change_ticket_status" then with_ticket("tickets.edit") { |t| change_status(t) }
        when "change_ticket_priority" then with_ticket("tickets.edit") { |t| change_priority(t) }
        when "assign_ticket" then with_ticket("tickets.assign") { |t| assign(t) }
        when "create_todo" then create_todo
        when "create_idea" then create_idea
        end
      end

      def payload = @proposal.payload

      # A project no longer visible is the same refusal for every kind (CYRA-907).
      def not_visible_if(result, code)
        result.err? && result.error.code == code ? err("R404-PROPOSAL-001", :not_visible) : result
      end

      def create_ticket
        not_visible_if(Ticketing::CreateTicket.call(
          organization: @organization, reporter: @account, true_actor: @true_actor,
          params: { project_id: payload["project_id"], title: payload["title"], description: payload["description"],
                    kind: payload["ticket_kind"], status_id: Ticketing::FormOptions.default_status_id(@organization),
                    priority_id: payload["priority_id"].presence || Ticketing::FormOptions.default_priority_id(@organization) }
        ), "R404-TICKET-001")
      end

      def with_ticket(permission)
        ticket = Ticketing::Ticket.where(project_id: visible.projects.select(:id)).find_by(id: payload["ticket_id"])
        return err("R404-PROPOSAL-001", :not_visible) if ticket.nil?
        return err("R403-PROPOSAL-001", :forbidden) if permission && !resolver.can?(permission, scope: ticket.project)

        yield ticket
      end

      def change_status(ticket)
        Ticketing::ChangeStatus.call(organization: @organization, ticket: ticket, status_id: payload["status_id"],
                                     channel: :web, actor: @account, true_actor: @true_actor)
      end

      # UpdateTicket replaces every field it receives: send the current ones with the new priority.
      def change_priority(ticket)
        Ticketing::UpdateTicket.call(organization: @organization, ticket: ticket, channel: :web,
                                     actor: @account, true_actor: @true_actor,
                                     params: current_ticket_params(ticket).merge(priority_id: payload["priority_id"]))
      end

      def current_ticket_params(ticket)
        { title: ticket.title, kind: ticket.kind, description: ticket.description,
          technical_analysis: ticket.technical_analysis, weight: ticket.weight, due_at: ticket.due_at,
          parent_id: ticket.parent_id, platform_ids: ticket.platform_ids,
          status_id: ticket.status_id, assignee_id: ticket.assignee_id, milestone_id: ticket.milestone_id }
      end

      def assign(ticket)
        Ticketing::AssignTicket.call(organization: @organization, ticket: ticket, assignee_id: payload["assignee_id"],
                                     actor: @account, true_actor: @true_actor)
      end

      def create_todo
        list = Todos::List.for(account: @account, organization: @organization).find_by(id: payload["list_id"])
        return err("R404-PROPOSAL-001", :not_visible) if list.nil?

        Todos::Items::Save.call(item: list.items.build, attributes: { title: payload["title"] })
      end

      def create_idea
        not_visible_if(Ideas::CreateIdea.call(organization: @organization, author: @account, true_actor: @true_actor,
                                              params: { project_id: payload["project_id"], title: payload["title"],
                                                        problem: payload["problem"] }), "R404-IDEA-001")
      end

      def finish(result)
        if result.ok?
          record = result.value
          @proposal.update!(status: :confirmed, confirmed_at: Time.current, error_code: nil,
                            result_type: record.class.name, result_id: record.id)
        else
          @proposal.update!(status: :failed, error_code: result.error.code)
        end
      end

      def visible = @visible ||= Authorization::VisibleScope.new(account: @account, organization: @organization)
      def resolver = @resolver ||= Authorization::Resolver.new(account: @account, organization: @organization)

      def err(code, key)
        Result.err(AppError.new(I18n.t("member.assistant.proposals.errors.#{key}"), code: code,
                                status: code.start_with?("R409") ? :conflict : :unprocessable_content))
      end
    end
  end
end
