# frozen_string_literal: true

module Github
  module Issues
    # The comments of a linked issue on its ticket. Each imported comment keeps its GitHub twin (id),
    # who wrote it there and whether it entered cut; the original on GitHub always stays whole. CYRA-1055
    module Comments
      module_function

      # nil when the comment is already here, empty, or lost a race with its own twin delivery.
      def import(link:, comment:, account:, notify: true)
        id = comment["id"]
        return nil if id.blank? || Ticketing::Comment.exists?(github_comment_id: id)

        body, cut = Text.comment(comment["body"], comment["html_url"].presence || link.html_url)
        return nil if body.blank?

        Outbound.suppress do
          Ticketing::AddComment.call(
            ticket: link.ticket, author: account, notify:, params: { body: },
            github: { github_comment_id: id, github_author_login: comment.dig("user", "login"), github_truncated: cut }
          )
        end
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      # Only a comment born on GitHub follows its edits: a CloseYourIt comment is the original.
      def edit(comment:, link:)
        record = imported(link, comment["id"])
        return nil if record.nil?

        body, cut = Text.comment(comment["body"], comment["html_url"].presence || link.html_url)
        record.update!(body:, github_truncated: cut) if body.present?
        record
      end

      def delete(comment:, link:, account:)
        record = imported(link, comment["id"])
        return nil if record.nil?

        Outbound.suppress { Ticketing::DeleteComment.call(comment: record, actor: account) }
      end

      # Every comment already on the issue, page after page (the first import, a card entering the board).
      def import_all(link:, account:, notify: false, since: nil, client: Github::Client.new)
        repository = link.repository
        imported = 0
        (1..).each do |page|
          batch = client.issue_comments(repository.github_installation_id, repository.full_name, link.number,
                                        since:, page:)
          batch.each { |comment| imported += 1 if import(link:, comment:, account:, notify:)&.ok? }
          break if batch.size < Github::Client::ISSUES_PAGE_SIZE
        end
        imported
      end

      def imported(link, github_comment_id)
        return nil if github_comment_id.blank?

        link.ticket.comments.where.not(github_author_login: nil).find_by(github_comment_id:)
      end
    end
  end
end
