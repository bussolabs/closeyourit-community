# frozen_string_literal: true

module Assistant
  module Tools
    # The ideas of ONE project, the most recently discussed first.
    class ListIdeas < Base
      STATUSES = %w[open converted archived].freeze
      PROBLEM_CHARS = 200

      def self.declaration
        { name: "list_ideas",
          description: "Lists the ideas of ONE project: title, problem, votes and comments. " \
                       "Use it for questions like 'which ideas are there for CYRA?' or 'which idea has the most votes?'.",
          parameters: {
            type: "OBJECT",
            properties: {
              project: { type: "STRING", description: "Project key, e.g. CYRA" },
              status: { type: "STRING", enum: STATUSES,
                        description: "open = open (default), converted = turned into tickets, archived = archived" }
            },
            required: [ "project" ]
          } }
      end

      def call(args)
        project = context.find_project(args["project"])
        return not_visible(args["project"]) if project.nil?

        status = STATUSES.include?(args["status"]) ? args["status"] : "open"
        scope = ::Ideas::Idea.where(project_id: project.id, status: status)
        rows = scope.by_last_activity.includes(:author).limit(MAX_ROWS).map { |idea| row(idea) }

        { project: project.key, status: status, total: scope.count, showing: rows.size, ideas: rows }
      end

      private

      def row(idea)
        { title: idea.title, status: idea.status, votes: idea.votes_count, comments: idea.comments_count,
          author: idea.author&.name, problem: idea.problem.to_s.first(PROBLEM_CHARS) }
      end
    end
  end
end
