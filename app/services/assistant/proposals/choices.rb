# frozen_string_literal: true

module Assistant
  module Proposals
    # What a card may let the user pick, in the same scopes the tools use: an id outside them is
    # never accepted, and the label shown on the card follows the id (CYRA-907).
    class Choices
      LABEL_KEYS = { "project_id" => "project_key", "priority_id" => "priority_label", "status_id" => "status_label",
                     "assignee_id" => "assignee_name", "list_id" => "list_name" }.freeze

      def initialize(account:, organization:)
        @account = account
        @organization = organization
        @rows = {}
      end

      def options(key) = rows(key).map { |label, id, _| [ label, id ] }

      # Payload changes for a chosen id, or nil when the id is outside the scope.
      def payload_for(key, id)
        row = rows(key).find { |_, row_id, _| row_id == id.to_s }
        row && { key => row[1], LABEL_KEYS.fetch(key) => row[2] }
      end

      private

      def rows(key)
        @rows[key] ||= case key
        when "project_id" then projects
        when "priority_id" then types(@organization.ticket_priorities)
        when "status_id" then types(@organization.ticket_statuses)
        when "assignee_id" then @organization.accounts.order(:name).map { |a| [ a.name, a.id, a.name ] }
        when "list_id" then Todos::List.for(account: @account, organization: @organization).ordered.map { |l| [ l.name, l.id, l.name ] }
        else []
        end
      end

      def projects
        Authorization::VisibleScope.new(account: @account, organization: @organization).projects.order(:key)
                                   .map { |p| [ "#{p.key} · #{p.name}", p.id, p.key ] }
      end

      def types(relation) = relation.active.ordered.map { |t| [ t.display_label, t.id, t.display_label ] }
    end
  end
end
