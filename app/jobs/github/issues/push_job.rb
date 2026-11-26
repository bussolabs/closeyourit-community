# frozen_string_literal: true

module Github
  module Issues
    # Sends a linked ticket's changes to its issue (Github::Issues::Push), one at a time per issue, in
    # line with the deliveries arriving from GitHub. A missing permission or a deleted issue is a fact,
    # not a hiccup: it is logged and not retried; the nightly check tries again. CYRA-1055
    class PushJob < ApplicationJob
      PUSHED_FIELDS = { title: "title", body: "description", state: "status", labels: "kind", assignees: "assignee" }.freeze

      queue_as :default

      limits_concurrency to: 1, key: ->(ticket_id:, **) { "github:issue:#{Github::Issue.where(ticket_id:).pick(:node_id) || ticket_id}" },
                         group: "github:issue"

      def perform(ticket_id:, reconcile: false)
        ticket = Ticketing::Ticket.find_by(id: ticket_id)
        return if ticket.nil?

        result = Github::Issues::Push.call(ticket:)
        record_repair(ticket, result.value) if reconcile && result.ok?
      rescue Github::Client::Error => e
        raise if e.transient?

        Rails.logger.warn("[github.issues.push] #{e.code} ticket=#{ticket_id}: #{e.message}")
      end

      private

      def record_repair(ticket, sent)
        fields = Array(sent).filter_map { |key| PUSHED_FIELDS[key] }.uniq
        return if fields.empty?

        Ticketing::RecordActivity.call(ticket:, action: "github_reconciled",
                                       actor_name: I18n.t("member.tickets.activity.system.github"),
                                       data: { fields:, number: ticket.github_issue&.number }.compact)
      end
    end
  end
end
