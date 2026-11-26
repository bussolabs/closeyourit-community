# frozen_string_literal: true

module Github
  module Issues
    # What GitHub moves on a ticket goes through the same services as a person's change, signed by the
    # organization's GitHub account. UpdateTicket replaces every field it receives, so the current
    # values travel with the changed ones. CYRA-1055
    module TicketFields
      EVENT_FIELDS = { title: "title", description: "description", kind: "kind",
                       priority_id: "priority", assignee_id: "assignee" }.freeze

      module_function

      def current(ticket)
        {
          title: ticket.title, description: ticket.description, technical_analysis: ticket.technical_analysis,
          kind: ticket.kind, weight: ticket.weight, due_at: ticket.due_at, priority_id: ticket.priority_id,
          parent_id: ticket.parent_id, platform_ids: ticket.platform_ids, status_id: ticket.status_id,
          assignee_id: ticket.assignee_id, milestone_id: ticket.milestone_id
        }
      end

      def update(ticket, changes, actor:)
        Ticketing::UpdateTicket.call(organization: ticket.project.organization, ticket:, channel: :webhook,
                                     actor:, params: current(ticket).merge(changes))
      end

      # Closed → the first active "done" status; reopened → the default open one.
      def status_for(organization, closed:)
        return organization.ticket_statuses.active.where(category: :done).ordered.first if closed

        organization.ticket_statuses.find_by(id: Ticketing::FormOptions.default_status_id(organization))
      end

      def change_status(ticket, status, actor:)
        Ticketing::ChangeStatus.call(organization: ticket.project.organization, ticket:, status_id: status.id,
                                     channel: :webhook, actor:)
      end

      def event_fields(changes) = changes.keys.filter_map { |key| EVENT_FIELDS[key.to_sym] }
    end
  end
end
