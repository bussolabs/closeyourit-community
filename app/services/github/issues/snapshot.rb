# frozen_string_literal: true

module Github
  module Issues
    # The fields that travel, read on each side in a shape that compares. The link keeps the last pair
    # seen: a side whose value moved since then is the side that changed. CYRA-1055
    module Snapshot
      # Remote field → the ticket fields it drives.
      LOCAL_FIELDS = {
        "title" => %w[title],
        "body" => %w[description files],
        "closed" => %w[closed],
        "labels" => %w[kind priority_id],
        "assignees" => %w[assignee_id]
      }.freeze
      REMOTE_FIELDS = LOCAL_FIELDS.keys.freeze

      module_function

      def remote(issue)
        {
          "title" => issue["title"].to_s,
          "body" => Text.without_attachments(LengthBudget.normalize_newlines(issue["body"])),
          "closed" => issue["state"] == "closed",
          "labels" => Array(issue["labels"]).filter_map { |label| label_name(label) }.sort,
          "assignees" => Array(issue["assignees"]).filter_map { |user| user.is_a?(Hash) ? user["login"].presence : nil }.sort
        }
      end

      def local(ticket)
        {
          "title" => ticket.title.to_s,
          "description" => ticket.description.to_s,
          "files" => ticket.files_attachments.map(&:id).sort,
          "closed" => ticket.status.category_done?,
          "status_id" => ticket.status_id,
          "kind" => ticket.kind,
          "priority_id" => ticket.priority_id,
          "assignee_id" => ticket.assignee_id
        }
      end

      # The remote fields whose ticket side moved since the last sync.
      def local_changes(link, ticket)
        before = link.local_state
        now = local(ticket)
        REMOTE_FIELDS.select { |field| LOCAL_FIELDS[field].any? { |key| before.key?(key) && before[key] != now[key] } }
      end

      # GitHub's clock of a change. Unreadable counts as absent: it cannot be ordered, and must not fail the rest.
      def time(value)
        value.present? ? Time.zone.parse(value.to_s) : nil
      rescue ArgumentError
        nil
      end

      def label_name(label)
        (label.is_a?(Hash) ? label["name"] : label).to_s.strip.presence
      end
    end
  end
end
