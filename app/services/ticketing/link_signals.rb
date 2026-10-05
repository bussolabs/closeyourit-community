# frozen_string_literal: true

module Ticketing
  # Links the monitoring signals picked in the new-ticket form (an error group, a slow operation) to
  # the bug that was just created — the same link a "promote to ticket" writes, started from the
  # ticket side. Fail-soft: a choice that does not hold (not a bug, another project, already linked,
  # no permission) is dropped and the ticket stays as created. Returns the groups actually linked.
  class LinkSignals < ApplicationService
    # Param name → association on the ticket's project + the permission a promotion asks for.
    SIGNALS = {
      error_group_id: { association: :error_groups, permission: "errors.promote" },
      metric_group_id: { association: :metric_groups, permission: "metrics.promote" }
    }.freeze

    def initialize(ticket:, actor:, organization:, error_group_id: nil, metric_group_id: nil)
      @ticket = ticket
      @actor = actor
      @organization = organization
      @ids = { error_group_id:, metric_group_id: }
    end

    def call
      return [] unless @ticket.kind_bug?

      SIGNALS.filter_map { |param, signal| link(@ids[param], **signal) }
    end

    private

    def link(id, association:, permission:)
      return if id.blank? || !resolver.can?(permission, scope: @ticket.project)

      group = @ticket.project.public_send(association).find_by(id: id)
      return if group.nil?

      # The lock serialises against a concurrent promotion of the same group (one ticket per group).
      group.with_lock { group.promoted? ? nil : group.tap { group.update!(ticket: @ticket) } }
    end

    def resolver
      @resolver ||= Authorization::Resolver.new(account: @actor, organization: @organization)
    end
  end
end
