# frozen_string_literal: true

module Github
  module Issues
    # The nightly check of one repository: GitHub does not deliver again what it failed to deliver.
    # Issues changed since the last check are applied with the usual rule (the newer change wins), cards
    # are realigned with the board, and every ticket change still owed to GitHub is sent. Each repair is
    # written in the ticket's history. CYRA-1055
    class Reconcile < ApplicationService
      # Overlap with the previous check: a change written while it was running is read again, not lost.
      OVERLAP = 1.hour

      def initialize(repository:, client: Github::Client.new)
        @repository = repository
        @client = client
      end

      def call
        return Result.ok(nil) unless @repository.issue_sync_live?

        started_at = Time.current
        remote_issues
        board_cards if @repository.board_configured?
        pending_pushes
        @repository.update_columns(issues_reconciled_at: started_at)
        Result.ok(nil)
      end

      private

      def since = @repository.issues_reconciled_at&.-(OVERLAP)
      def installation_id = @repository.github_installation_id

      # Never checked before: only the open issues, as the first import does.
      def remote_issues
        state = since ? "all" : "open"
        (1..).each do |page|
          batch = @client.repository_issues(installation_id, @repository.full_name, state:, since:, page:)
          batch.each { |issue| remote_issue(issue) }
          break if batch.size < Github::Client::ISSUES_PAGE_SIZE
        end
      end

      def remote_issue(issue)
        link = @repository.issues.find_by(number: issue["number"])
        return import(issue) if link.nil?

        Apply.call(link:, issue:, reconcile: true)
        missed = Comments.import_all(link:, account: signature, notify: true, since:, client: @client)
        record(link.ticket, %w[comments]) if missed.positive?
      end

      # Every open issue when the project takes them all; board issues come in through board_cards.
      def import(issue)
        return unless @repository.issue_sync_all_issues? && issue["state"] == "open"

        Import.call(repository: @repository, issue:, with_comments: true)
      end

      def board_cards
        items = @client.board_items(installation_id, @repository.board_node_id)
                       .select { |item| item[:repo_id] == @repository.repo_id }
        items.each { |item| board_card(item) }
        drop_left_cards(items.map { |item| item[:number] }) if @repository.issue_sync_board_issues?
      end

      def board_card(item)
        link = @repository.issues.find_by(number: item[:number])
        before = link&.ticket&.status_id
        board(item[:item_id], "edited", item:)
        record(link.ticket, %w[status]) if link && link.ticket.reload.status_id != before
      end

      # A card that left the board while nobody was listening: the link breaks, the ticket stays.
      def drop_left_cards(on_board)
        @repository.issues.where.not(number: on_board).where.not(board_item_node_id: nil).find_each do |link|
          board(link.board_item_node_id, "deleted")
        end
      end

      def board(item_node_id, action, item: nil)
        Board.call(installation: @repository.installation, board_node_id: @repository.board_node_id,
                   item_node_id:, action:, item:, client: @client)
      end

      # Use the same per-issue queue as webhook deliveries and ordinary pushes.
      def pending_pushes
        @repository.issues.find_each do |link|
          PushJob.perform_later(ticket_id: link.ticket_id, reconcile: true)
        end
      end

      def record(ticket, fields)
        return if fields.empty?

        Ticketing::RecordActivity.call(ticket:, action: "github_reconciled",
                                       actor_name: I18n.t("member.tickets.activity.system.github"),
                                       data: { fields:, number: ticket.github_issue&.number }.compact)
      end

      def signature
        @signature ||= SystemAccount.call(installation: @repository.installation, project: @repository.project).value
      end
    end
  end
end
