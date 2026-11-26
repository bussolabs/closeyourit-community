# frozen_string_literal: true

module Github
  module Webhooks
    # Event `issues`: a linked issue updates its ticket; an open issue without a ticket becomes one when
    # the project takes every issue, or when it sits on the chosen board. Deliveries caused by this app,
    # and repositories with the sync off, change nothing. CYRA-1055
    class Issues < Base
      NUMBER_RANGE = (1..2_147_483_647)

      def call
        repo = repository
        return Result.ok(nil) if repo.nil? || !repo.issue_sync_active?

        issue = object_at(@payload, "issue")
        number = value_at(issue, "number")
        return Result.ok(nil) unless number.to_s.match?(/\A\d+\z/) && NUMBER_RANGE.cover?(number.to_i)
        return Result.ok(nil) if issue.key?("pull_request") || from_this_app?(issue)

        link = repo.issues.find_by(number: number.to_i)
        return unlink(link) if %w[deleted transferred].include?(value_at(@payload, "action"))
        return Github::Issues::Apply.call(link:, issue:, login: sender_login) if link

        import(repo, issue)
      end

      private

      # Only open issues come in: an old closed one touched again stays on GitHub.
      def import(repo, issue)
        return Result.ok(nil) if value_at(issue, "state") == "closed"
        return Github::Issues::Import.call(repository: repo, issue:) if repo.issue_sync_all_issues?

        item = board_item(repo, issue)
        return Result.ok(nil) if item.nil?

        Github::Issues::Import.call(repository: repo, issue:, board_item: item, with_comments: true)
      end

      def board_item(repo, issue)
        node_id = value_at(issue, "node_id")
        return nil if node_id.blank? || repo.board_node_id.blank?

        Github::Client.new.issue_board_items(installation.installation_id, node_id)
                      .find { |item| item[:board_id] == repo.board_node_id }
      end

      # The issue left this repository: the link breaks, the ticket stays.
      def unlink(link)
        return Result.ok(nil) if link.nil?

        record_activity(link.ticket, "github_issue_unlinked", number: link.number, login: sender_login,
                        reason: value_at(@payload, "action"))
        link.destroy!
        Result.ok(nil)
      end
    end
  end
end
