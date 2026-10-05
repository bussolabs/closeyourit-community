# frozen_string_literal: true

module Assistant
  module Tools
    # Proposes a todo on one of the person's own lists; todos have no due date (CYRA-907).
    class ProposeTodo < ProposalTool
      def self.declaration
        { name: "propose_todo",
          description: "Proposes a personal todo. The user confirms it. Todos have no due date: keep " \
                       "any timing in the title.",
          parameters: {
            type: "OBJECT",
            properties: { title: { type: "STRING", description: "The todo" },
                          list: { type: "STRING", description: "List name, optional" } },
            required: %w[title]
          } }
      end

      def call(args)
        lists = Todos::List.for(account: context.account, organization: context.organization).ordered
        list = lists.find { |l| l.name.casecmp?(args["list"].to_s.strip) } || lists.first
        return { error: "Non hai ancora una lista di todo: creane una dalla pagina Todo." } if list.nil?

        propose(:create_todo, list_id: list.id, list_name: list.name, title: args["title"].to_s.strip)
      end
    end
  end
end
