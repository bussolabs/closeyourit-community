# frozen_string_literal: true

module Assistant
  module Tools
    # The slow operations of ONE project still to look at, the costliest first: the same order as
    # the Performance page (total time spent, not the rare peak).
    class ListPerformance < Base
      TITLE_CHARS = 160

      def self.declaration
        { name: "list_performance",
          description: "Lists the slow operations of ONE project still to look at, costliest first: " \
                       "what is slow, how long it takes on average and how many times it happened. " \
                       "Use it for questions like 'what is slow in CYRA?'.",
          parameters: {
            type: "OBJECT",
            properties: { project: { type: "STRING", description: "Project key, e.g. CYRA" } },
            required: [ "project" ]
          } }
      end

      def call(args)
        project = context.find_project(args["project"])
        return not_visible(args["project"]) if project.nil?

        scope = ::Metrics::Group.where(project_id: project.id).status_unresolved
        rows = scope.costliest_first.limit(MAX_ROWS).map { |group| row(group) }

        { project: project.key, total: scope.count, showing: rows.size, operations: rows }
      end

      private

      def row(group)
        { title: label(group).first(TITLE_CHARS), kind: group.subtype.presence || group.kind,
          average_ms: group.average_duration_ms.round, samples: group.samples_count,
          last_seen: group.last_seen_at&.iso8601 }
      end

      # A query reads as "Read · tickets" on the page: the raw SQL would only add noise here.
      def label(group) = (group.kind_slow_query? ? group.query_label.to_s : group.title).to_s
    end
  end
end
