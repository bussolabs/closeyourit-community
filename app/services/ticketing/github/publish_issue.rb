# frozen_string_literal: true

module Ticketing
  module Github
    # Publishes a ticket born on CloseYourIt as an issue of the project's repository and links them: from
    # then on they stay aligned. With a board chosen the issue goes on it, in the column of the ticket's
    # status. Shared by Member and CLI. CYRA-1055
    class PublishIssue < ApplicationService
      def initialize(ticket:, actor:, true_actor: nil, client: ::Github::Client.new)
        @ticket = ticket
        @actor = actor
        @true_actor = true_actor
        @client = client
      end

      def call
        repository = @ticket.project.github_repository
        return err("R404-GITHUB-002", :not_found, "github.errors.no_repo") if repository.nil?
        return err("R422-GITHUB-013", :unprocessable_content, "github.issues.errors.sync_off") unless repository.issue_sync_live?

        claimed = claim
        return claimed if claimed.err?

        issue = claimed.value
        unless issue
          issue = create_issue(repository)
          @ticket.update_columns(github_issue_publication: { "issue" => issue })
        end
        linked = link_issue(repository, issue)
        return linked if linked.err?

        add_to_board(repository, linked.value)
        linked
      rescue ::Github::Client::Error => e
        @ticket.update_columns(github_issue_publication: {}) if @claimed && !e.transient?
        Result.err(AppError.new(I18n.t("github.issues.errors.publish_failed"), code: "R422-GITHUB-015",
                                status: :unprocessable_content, details: { github: [ e.code ] }))
      end

      private

      # Commit the claim before HTTP. An uncertain response keeps it for a person to reconcile.
      def claim
        @ticket.with_lock do
          return err("R409-GITHUB-014", :conflict, "github.issues.errors.already_published") if ::Github::Issue.exists?(ticket_id: @ticket.id)

          state = @ticket.github_issue_publication
          return Result.ok(state["issue"]) if state["issue"]
          return err("R409-GITHUB-016", :conflict, "github.issues.errors.publish_pending") if state.present?

          @ticket.update_columns(github_issue_publication: { "claimed_at" => Time.current.iso8601 })
          @claimed = true
          Result.ok(nil)
        end
      end

      # Keep the received issue on a local failure so retrying only repeats the local write.
      def link_issue(repository, issue)
        @ticket.with_lock do
          existing = repository.issues.find_by(node_id: issue["node_id"]) if issue["node_id"].present?
          if existing && existing.ticket_id != @ticket.id
            return err("R409-GITHUB-016", :conflict, "github.issues.errors.publish_pending")
          end

          link = existing || persist!(repository, issue)
          @ticket.update_columns(github_issue_publication: {})
          Result.ok(link)
        end
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        err("R409-GITHUB-016", :conflict, "github.issues.errors.publish_pending")
      end

      def create_issue(repository)
        login = @ticket.assignee&.github_login
        @client.create_issue(
          repository.github_installation_id, repository.full_name,
          title: @ticket.title, body: ::Github::Issues::Text.issue_body(@ticket),
          labels: [ repository.label_for_kind(@ticket.kind), repository.label_for_priority(@ticket.priority_id) ].compact,
          assignees: login.present? ? [ login ] : nil
        )
      end

      def persist!(repository, issue)
        ApplicationRecord.transaction do
          link = repository.issues.create!(
            ticket: @ticket, number: issue["number"], github_id: issue["id"], node_id: issue["node_id"],
            html_url: issue["html_url"], author_login: issue.dig("user", "login"),
            github_updated_at: ::Github::Issues::Snapshot.time(issue["updated_at"]),
            synced_state: { "remote" => ::Github::Issues::Snapshot.remote(issue),
                            "local" => ::Github::Issues::Snapshot.local(@ticket) }
          )
          RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor, action: "github_issue_published",
                              data: { number: link.number, url: link.html_url })
          link
        end
      end

      # The issue exists already: a board GitHub refuses leaves it off the board, the nightly check retries.
      def add_to_board(repository, link)
        return unless repository.board_configured? && link.node_id.present?

        item_id = @client.add_board_item(repository.github_installation_id, repository.board_node_id, link.node_id)
        option = repository.option_for_status(@ticket.status_id)
        if item_id && option
          @client.move_board_item(repository.github_installation_id, repository.board_node_id, item_id,
                                  repository.board_status_field_id, option)
        end
        link.update!(board_item_node_id: item_id, board_option_id: option)
      rescue ::Github::Client::Error => e
        Rails.logger.warn("[github.issues.publish] board #{e.code} ticket=#{@ticket.code}")
      end

      def err(code, status, key)
        Result.err(AppError.new(I18n.t(key), code:, status:))
      end
    end
  end
end
