# frozen_string_literal: true

module Github
  module Issues
    # What the GitHub tab needs to set the issue sync up, read live from GitHub: the organization boards,
    # the columns of the chosen one, and the App permissions still missing. A permission GitHub has not
    # granted is named on the page instead of failing silently later. CYRA-1055
    class Setup < ApplicationService
      View = Data.define(:boards, :columns, :missing_permissions, :unreadable)

      # GitHub permission → the level the sync needs. Boards are an organization permission.
      NEEDED = { "issues" => "write" }.freeze
      NEEDED_FOR_BOARD = { "organization_projects" => "write" }.freeze

      def initialize(repository:, client: Github::Client.new)
        @repository = repository
        @client = client
      end

      def call
        installation = @repository.installation
        permissions = @client.installation(installation.installation_id)["permissions"].to_h
        Result.ok(View.new(boards: boards(installation), columns:, missing_permissions: missing(permissions),
                           unreadable: false))
      rescue Github::Client::Error
        Result.ok(View.new(boards: [], columns: [], missing_permissions: [], unreadable: true))
      end

      private

      def missing(permissions)
        needed = NEEDED.merge(NEEDED_FOR_BOARD)
        needed.reject { |name, level| permissions[name] == level || (level == "read" && permissions[name] == "write") }.keys
      end

      def boards(installation)
        @client.organization_boards(installation.installation_id, installation.account_login)
      rescue Github::Client::Error
        []
      end

      def columns
        return [] unless @repository.board_configured?

        board = @client.board(@repository.github_installation_id, @repository.board_node_id)
        Array(board&.dig(:field, "options"))
      rescue Github::Client::Error
        []
      end
    end
  end
end
