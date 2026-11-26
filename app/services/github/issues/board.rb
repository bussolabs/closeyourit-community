# frozen_string_literal: true

module Github
  module Issues
    # A card of an organization board moves its ticket. Moving a card to a column sets the status mapped
    # to that column; a card entering the board brings its issue in when the project takes board issues;
    # a card leaving the board breaks the link and the ticket stays. CYRA-1055
    class Board < ApplicationService
      # `item`: the card already read (the nightly check reads the whole board in one go).
      def initialize(installation:, board_node_id:, item_node_id:, action:, login: nil, item: nil,
                     client: Github::Client.new)
        @installation = installation
        @board_node_id = board_node_id
        @item_node_id = item_node_id
        @action = action
        @login = login
        @item = item
        @client = client
      end

      def call
        repositories = @installation.repositories.where(board_node_id: @board_node_id).select(&:issue_sync_active?)
        return Result.ok(nil) if repositories.empty?
        return leave(repositories) if %w[deleted archived].include?(@action)

        item = @item || @client.board_item(@installation.installation_id, @item_node_id)
        repository = item && repositories.find { |candidate| candidate.repo_id == item[:repo_id] }
        return Result.ok(nil) if repository.nil?

        link = repository.issues.find_by(number: item[:number])
        link ? move(repository, link, item) : enter(repository, item)
      end

      private

      # With every issue synced the link stays and only forgets the card.
      def leave(repositories)
        link = Github::Issue.where(repository: repositories).find_by(board_item_node_id: @item_node_id)
        return Result.ok(nil) if link.nil?

        unless link.repository.issue_sync_board_issues?
          link.update!(board_item_node_id: nil, board_option_id: nil)
          return Result.ok(link)
        end

        Ticketing::RecordActivity.call(ticket: link.ticket, action: "github_issue_unlinked",
                                       actor_name: I18n.t("member.tickets.activity.system.github"),
                                       data: { number: link.number, login: @login }.compact)
        link.destroy!
        Result.ok(nil)
      end

      def enter(repository, item)
        issue = @client.issue(@installation.installation_id, repository.full_name, item[:number])
        return Result.ok(nil) if issue.nil?

        Import.call(repository:, issue:, board_item: item, with_comments: true)
      end

      # The column → status mapped to it. A refused move stays written in the ticket's history.
      def move(repository, link, item)
        option = item[:options][repository.board_status_field_id]
        link.update!(board_item_node_id: item[:item_id], board_option_id: option)
        status = repository.status_id_for_option(option).then { |id| id && link.ticket.project.organization.ticket_statuses.find_by(id:) }
        return Result.ok(link) if status.nil? || status.id == link.ticket.status_id

        result = Outbound.suppress { TicketFields.change_status(link.ticket, status, actor: signature(repository)) }
        return decline(link, status, result) if result.err?

        # The issue opens or closes with the column; the card stays where it is (Push#move_card).
        Github::Issues::PushJob.perform_later(ticket_id: link.ticket_id)
        Result.ok(link)
      end

      def decline(link, status, result)
        Ticketing::RecordActivity.call(ticket: link.ticket, action: "github_change_declined",
                                       actor_name: I18n.t("member.tickets.activity.system.github"),
                                       data: { number: link.number, login: @login, fields: %w[status], to: status.label,
                                               reason: result.error.code }.compact)
        Result.ok(link)
      end

      def signature(repository)
        result = SystemAccount.call(installation: @installation, project: repository.project)
        result.ok? ? result.value : nil
      end
    end
  end
end
