# frozen_string_literal: true

module Github
  module Webhooks
    # Event `issue_comment` on a linked issue: a new comment lands on the ticket signed GitHub, with the
    # writer's GitHub name beside it; edits and deletions follow it. Comments on pull requests and the
    # ones this app wrote are left alone. CYRA-1055
    class IssueComment < Base
      def call
        repo = repository
        return Result.ok(nil) if repo.nil? || !repo.issue_sync_active?

        issue = object_at(@payload, "issue")
        comment = object_at(@payload, "comment")
        return Result.ok(nil) if issue.key?("pull_request") || comment.empty? || from_this_app?(comment)

        link = repo.issues.find_by(number: value_at(issue, "number").to_i)
        return Result.ok(nil) if link.nil?

        dispatch(link, comment)
      end

      private

      def dispatch(link, comment)
        action = value_at(@payload, "action")
        if %w[created deleted].include?(action)
          signed = Github::Issues::SystemAccount.call(installation:, project: link.repository.project)
          return signed if signed.err?
        end

        case action
        when "created" then Github::Issues::Comments.import(link:, comment:, account: signed.value) || Result.ok(nil)
        when "edited" then Result.ok(Github::Issues::Comments.edit(comment:, link:))
        when "deleted" then Github::Issues::Comments.delete(comment:, link:, account: signed.value) || Result.ok(nil)
        else Result.ok(nil)
        end
      end
    end
  end
end
