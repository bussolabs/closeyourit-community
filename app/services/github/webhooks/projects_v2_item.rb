# frozen_string_literal: true

module Github
  module Webhooks
    # Event `projects_v2_item`: a card of an organization board was added, moved or removed. GitHub sends
    # it for organization boards only. The payload names no repository, so the board decides which
    # project it belongs to; a suspended organization moves nothing. CYRA-1055
    class ProjectsV2Item < Base
      ACTIONS = %w[created edited restored converted deleted archived].freeze

      def call
        item = object_at(@payload, "projects_v2_item")
        action = value_at(@payload, "action")
        return Result.ok(nil) unless ACTIONS.include?(action) && value_at(item, "content_type") == "Issue"
        return Result.ok(nil) if installation.nil? || installation.organization&.suspended? || from_this_app?

        Github::Issues::Board.call(installation:, board_node_id: value_at(item, "project_node_id"),
                                   item_node_id: value_at(item, "node_id"), action:, login: sender_login)
      end
    end
  end
end
