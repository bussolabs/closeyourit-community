# frozen_string_literal: true

module Github
  module Issues
    # An issue becomes a ticket of the repository's project, linked to it. The ticket is signed by the
    # organization's GitHub account and keeps the GitHub name of who opened the issue; a text longer
    # than the ticket holds enters cut, with a link to the original. CYRA-1055
    class Import < ApplicationService
      DEFAULT_KIND = "task"

      # `board_item`: the card when the issue enters through the board (Client#board_item shape).
      # `notify: false` for the first bulk import; `with_comments` brings the comments already written.
      def initialize(repository:, issue:, board_item: nil, notify: true, with_comments: false)
        @repository = repository
        @issue = issue
        @board_item = board_item
        @notify = notify
        @with_comments = with_comments
      end

      def call
        existing = @repository.issues.find_by(number: @issue["number"])
        return Result.ok(existing) if existing

        signature = SystemAccount.call(installation: @repository.installation, project:)
        return signature if signature.err?

        @account = signature.value
        description, cut = Text.description(@issue["body"], @issue["html_url"])
        assignee, unknown_login = People.resolve(organization, remote["assignees"])
        created, link = create_linked_ticket(description, assignee, cut)
        return created if created.err?
        return Result.ok(link) if @lost_race

        record(link, unknown_login)
        Comments.import_all(link:, account: @account, notify: @notify) if @with_comments
        Result.ok(link)
      end

      private

      def project = @repository.project
      def organization = project.organization
      def remote = @remote ||= Snapshot.remote(@issue)

      def create_linked_ticket(description, assignee, cut)
        created = nil
        link = ApplicationRecord.transaction(requires_new: true) do
          created = Outbound.suppress { create_ticket(description, assignee) }
          raise ActiveRecord::Rollback if created.err?

          create_link(created.value, cut)
        end
        [ created, link ]
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        winner = @repository.issues.find_by(number: @issue["number"])
        raise if winner.nil?

        @lost_race = true
        [ Result.ok(winner.ticket), winner ]
      end

      def create_ticket(description, assignee)
        Ticketing::CreateTicket.call(
          organization:, reporter: @account, notify: @notify, default_assignee: false, origin: :github_import,
          params: {
            project_id: project.id, title: Text.title(@issue["title"]), description:,
            kind: @repository.kind_for_labels(remote["labels"]) || DEFAULT_KIND,
            status_id: initial_status&.id || Ticketing::FormOptions.default_status_id(organization),
            priority_id: @repository.priority_id_for_labels(remote["labels"]) ||
                         Ticketing::FormOptions.default_priority_id(organization),
            assignee_id: assignee&.id,
            # The GitHub account signs; a person reviews: the project's owner.
            reviewer_id: project.owner_id
          }
        )
      end

      def initial_status
        return TicketFields.status_for(organization, closed: true) if remote["closed"]

        status_id = @repository.status_id_for_option(board_option)
        status_id && organization.ticket_statuses.find_by(id: status_id)
      end

      def board_option = @board_item && @board_item[:options][@repository.board_status_field_id]

      # The unique index arbitrates racing deliveries; the losing transaction rolls its ticket back.
      def create_link(ticket, cut)
        @repository.issues.create!(
          ticket:, number: @issue["number"], github_id: @issue["id"], node_id: @issue["node_id"],
          html_url: @issue["html_url"], author_login: @issue.dig("user", "login"),
          github_updated_at: Snapshot.time(@issue["updated_at"]),
          truncated_fields: cut ? %w[description] : [],
          board_item_node_id: @board_item&.dig(:item_id), board_option_id: board_option,
          synced_state: { "remote" => remote, "local" => Snapshot.local(ticket.reload) }
        )
      end

      def record(link, unknown_login)
        Ticketing::RecordActivity.call(ticket: link.ticket, actor: @account, action: "github_issue_imported",
                                       data: { number: link.number, login: link.author_login, url: link.html_url })
        return if unknown_login.nil?

        Ticketing::RecordActivity.call(ticket: link.ticket, actor: @account, action: "github_assignee_unknown",
                                       data: { number: link.number, login: unknown_login })
      end
    end
  end
end
