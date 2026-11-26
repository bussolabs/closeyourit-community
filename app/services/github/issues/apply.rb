# frozen_string_literal: true

module Github
  module Issues
    # The state of an issue lands on its linked ticket, field by field. A field GitHub changed since the
    # last sync is applied, unless the ticket changed it too and later: then the newer change wins, the
    # other stays written in the history, and the push sends the ticket's value. A delivery older than
    # the state already seen applies nothing. CYRA-1055
    class Apply < ApplicationService
      # `login`: who acted on GitHub. `reconcile`: the nightly check, which also says what it repaired.
      def initialize(link:, issue:, login: nil, reconcile: false)
        @link = link
        @issue = issue
        @login = login.presence || issue.dig("user", "login")
        @reconcile = reconcile
      end

      def call
        changed = Snapshot::REMOTE_FIELDS.select { |field| remote[field] != @link.remote_state[field] }
        return Result.ok([]) if changed.empty?
        return Result.ok([]) if stale?

        losing = ticket_newer? ? changed & Snapshot.local_changes(@link, ticket) : []
        applied = changed - losing
        @account = signature
        Outbound.suppress { apply(applied) }
        save_state(applied)
        superseded(losing, push: true) if losing.any?
        record("github_reconciled", fields: event_fields(applied)) if @reconcile && applied.any?
        Result.ok(applied)
      end

      private

      def ticket = @link.ticket
      def repository = @link.repository
      def organization = repository.project.organization
      def remote = @remote ||= Snapshot.remote(@issue)
      def delivered_at = @delivered_at ||= Snapshot.time(@issue["updated_at"])

      def stale? = delivered_at && @link.github_updated_at && delivered_at < @link.github_updated_at

      def ticket_newer? = delivered_at.nil? || ticket.updated_at > delivered_at

      def signature
        result = SystemAccount.call(installation: repository.installation, project: repository.project)
        result.ok? ? result.value : nil
      end

      def apply(fields)
        changes = {}
        changes[:title] = Text.title(@issue["title"]) if fields.include?("title")
        apply_body(changes) if fields.include?("body")
        apply_labels(changes) if fields.include?("labels")
        apply_assignees(changes) if fields.include?("assignees")
        update(changes) if changes.any?
        apply_closed if fields.include?("closed")
      end

      def apply_body(changes)
        description, cut = Text.description(@issue["body"], @issue["html_url"])
        changes[:description] = description
        @truncated = cut
      end

      def apply_labels(changes)
        kind = repository.kind_for_labels(remote["labels"])
        priority_id = repository.priority_id_for_labels(remote["labels"])
        changes[:kind] = kind if kind && kind != ticket.kind
        changes[:priority_id] = priority_id if priority_id && priority_id != ticket.priority_id
      end

      # A GitHub name nobody wrote in their profile leaves the ticket unassigned, and says so.
      def apply_assignees(changes)
        assignee, unknown_login = People.resolve(organization, remote["assignees"])
        changes[:assignee_id] = assignee&.id
        record("github_assignee_unknown", login: unknown_login) if unknown_login
      end

      def update(changes)
        result = TicketFields.update(ticket, changes, actor: @account)
        return if result.ok?

        record("github_change_declined", fields: TicketFields.event_fields(changes), reason: result.error.code)
      end

      # Prerequisites or a running automation may refuse the move: the refusal stays in the history.
      def apply_closed
        return if remote["closed"] == ticket.status.category_done?

        status = TicketFields.status_for(organization, closed: remote["closed"])
        result = status ? TicketFields.change_status(ticket, status, actor: @account) : nil
        return if result&.ok?

        record("github_change_declined", fields: %w[status], to: status&.label, reason: result&.error&.code)
      end

      # The remote side is now known; the local side moves only for what was applied, so a ticket
      # change still waiting for its push is not mistaken for synced.
      def save_state(applied)
        local = @link.local_state.dup
        now = Snapshot.local(ticket.reload)
        local = now if local.empty?
        applied.each { |field| Snapshot::LOCAL_FIELDS[field].each { |key| local[key] = now[key] } }
        @link.update!(synced_state: { "remote" => remote, "local" => local }, truncated_fields:,
                      github_updated_at: [ delivered_at, @link.github_updated_at ].compact.max)
      end

      def truncated_fields
        return @link.truncated_fields if @truncated.nil?

        @truncated ? (@link.truncated_fields | %w[description]) : (@link.truncated_fields - %w[description])
      end

      def superseded(fields, push: false)
        @account ||= signature
        record("github_change_superseded", fields: event_fields(fields))
        Github::Issues::PushJob.perform_later(ticket_id: ticket.id) if push
        Result.ok([])
      end

      def event_fields(fields)
        fields.flat_map { |field| { "body" => %w[description], "labels" => %w[kind priority],
                                    "assignees" => %w[assignee], "closed" => %w[status] }.fetch(field, [ field ]) }
      end

      def record(action, **data)
        Ticketing::RecordActivity.call(ticket:, actor: @account, action:,
                                       actor_name: I18n.t("member.tickets.activity.system.github"),
                                       data: { number: @link.number, login: @login }.merge(data).compact)
      end
    end
  end
end
