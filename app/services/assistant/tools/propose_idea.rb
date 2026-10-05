# frozen_string_literal: true

module Assistant
  module Tools
    # Proposes a project idea; similar ideas ride along so the card can warn (CYRA-907).
    class ProposeIdea < ProposalTool
      def self.declaration
        { name: "propose_idea",
          description: "Proposes a new idea for a project. The user confirms it.",
          parameters: {
            type: "OBJECT",
            properties: { project: { type: "STRING", description: "Project key or name" },
                          title: { type: "STRING", description: "Short title" },
                          problem: { type: "STRING", description: "The problem it solves, one sentence" } },
            required: %w[project title]
          } }
      end

      def call(args)
        project = context.find_project(args["project"])
        return not_visible(args["project"]) if project.nil?

        propose(:create_idea, project_id: project.id, project_key: project.key,
                              title: args["title"].to_s.strip, problem: args["problem"].to_s.strip,
                              similar: similar(project, args))
      end

      private

      def similar(project, args)
        result = Ideas::FindSimilarIdeas.call(scope: project.ideas, text: "#{args['title']} #{args['problem']}")
        result.ok? ? result.value.first(3).map { |idea| { title: idea.title } } : []
      end
    end
  end
end
