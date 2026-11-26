# frozen_string_literal: true

module Github
  module Issues
    # A linked ticket's changes go to its issue: only the fields that moved on the ticket since the
    # last sync, so a change that just arrived from GitHub is never sent back. A description that
    # entered cut is never sent: it would erase the longer original on GitHub. The board card follows
    # the status when the repository maps that status to a column. CYRA-1055
    class Push < ApplicationService
      def initialize(ticket:, client: Github::Client.new)
        @ticket = ticket
        @client = client
      end

      def call
        @link = @ticket.github_issue
        return Result.ok(nil) if @link.nil? || !repository.issue_sync_live?

        attributes = changed_attributes
        response = attributes.any? ? @client.update_issue(installation_id, repository.full_name, @link.number, attributes) : nil
        save_state(response)
        move_card
        Result.ok(attributes.keys)
      end

      private

      def repository = @link.repository
      def installation_id = repository.github_installation_id

      def changed_attributes
        Snapshot.local_changes(@link, @ticket).each_with_object({}) do |field, attributes|
          case field
          when "title" then attributes[:title] = @ticket.title
          when "body" then body(attributes)
          when "closed" then state(attributes)
          when "labels" then attributes[:labels] = labels
          when "assignees" then assignees(attributes)
          end
        end
      end

      def body(attributes)
        if @link.truncated?("description")
          @kept = true
        else
          attributes[:body] = Text.issue_body(@ticket)
        end
      end

      def state(attributes)
        closed = @ticket.status.category_done?
        attributes[:state] = closed ? "closed" : "open"
        attributes[:state_reason] = closed ? "completed" : "reopened"
      end

      # The labels that stand for a type or a priority follow the ticket; every other label stays.
      def labels
        managed = repository.managed_labels
        kept = Array(@link.remote_state["labels"]).reject { |label| managed.include?(label.downcase) }
        (kept + [ repository.label_for_kind(@ticket.kind), repository.label_for_priority(@ticket.priority_id) ]).compact.uniq
      end

      # An assignee without a GitHub name in the profile leaves the issue's assignees as they are.
      def assignees(attributes)
        assignee = @ticket.assignee
        if assignee.nil?
          attributes[:assignees] = []
        elsif assignee.github_login.present?
          attributes[:assignees] = [ assignee.github_login ]
        end
      end

      def save_state(response)
        remote = response ? Snapshot.remote(response) : @link.remote_state
        @link.update!(synced_state: { "remote" => remote, "local" => Snapshot.local(@ticket) },
                      github_updated_at: [ Snapshot.time(response&.dig("updated_at")), @link.github_updated_at ].compact.max)
        return unless @kept

        Ticketing::RecordActivity.call(ticket: @ticket, action: "github_text_kept",
                                       actor_name: I18n.t("member.tickets.activity.system.github"),
                                       data: { number: @link.number })
      end

      # A card already in a column mapped to the ticket's status stays put: moving it to the first such
      # column would answer a person's move with another move.
      def move_card
        return unless repository.board_configured? && @link.board_item_node_id.present?
        return if repository.status_id_for_option(@link.board_option_id) == @ticket.status_id

        option = repository.option_for_status(@ticket.status_id)
        return if option.nil? || option == @link.board_option_id

        @client.move_board_item(installation_id, repository.board_node_id, @link.board_item_node_id,
                                repository.board_status_field_id, option)
        @link.update!(board_option_id: option)
      end
    end
  end
end
