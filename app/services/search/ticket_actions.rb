# frozen_string_literal: true

module Search
  # The actions the quick search offers on the open ticket (CYRA-1145). Each one names the endpoint of
  # the button that already does it, which checks the permission again: `blocked` only greys it out.
  class TicketActions
    Action = Data.define(:kind, :label, :ticket, :value, :blocked)

    PERMISSIONS = { assign: "tickets.assign", status: "tickets.edit", automation: "tickets.edit" }.freeze

    def initialize(ticket:, viewer:, organization:, can:)
      @ticket = ticket
      @viewer = viewer
      @organization = organization
      @can = can
    end

    # Every word typed must appear in the label or in the action's own search words.
    def matching(query)
      words = query.downcase.split
      candidates.select { |kind, label, _value| words.all? { |word| haystack(kind, label).include?(word) } }
                .map { |kind, label, value| Action.new(kind:, label:, ticket: @ticket, value:, blocked: blocked(kind)) }
    end

    private

    def candidates
      list = []
      list << [ :assign, I18n.t("member.search.actions.assign.label"), @viewer.id ] unless @ticket.assignee_id == @viewer.id
      @organization.ticket_statuses.active.ordered.where.not(id: @ticket.status_id).each do |status|
        list << [ :status, I18n.t("member.search.actions.status.label", status: status.display_label), status.id ]
      end
      list << [ :automation, I18n.t("member.search.actions.automation.label"), "allowed" ] unless @ticket.agent_eligibility_allowed?
      list
    end

    def haystack(kind, label)
      "#{label} #{I18n.t("member.search.actions.#{kind}.terms")}".downcase
    end

    # Why the viewer cannot run it, or nil when they can: the same gate as the ticket page.
    def blocked(kind)
      key = PERMISSIONS.fetch(kind)
      @allowed ||= {}
      @allowed[key] = @can.call(key, scope: @ticket.project) unless @allowed.key?(key)
      return if @allowed[key]

      kind == :assign ? :assign : :edit
    end
  end
end
