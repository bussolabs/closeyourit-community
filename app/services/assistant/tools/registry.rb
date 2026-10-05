# frozen_string_literal: true

module Assistant
  module Tools
    # L'elenco degli attrezzi dell'assistente: unico punto da cui si sa cosa può fare.
    #
    # Aggiungere una capacità = aggiungere una classe qui sotto.
    # Write tools only propose (Assistant::Proposal) and exist only on the web channel (CYRA-907).
    module Registry
      TOOLS = [ ListProjects, SearchTickets, GetTicket, AskTickets, AskKnowledge, ProjectHealth,
                ListErrors, ListPerformance, SearchLogs, ListMonitors, ListReleases, ListIdeas ].freeze

      WRITE_TOOLS = [ ProposeTicket, ProposeComment, ProposeStatus, ProposePriority, ProposeAssignee,
                      ProposeTodo, ProposeIdea ].freeze

      BY_NAME = TOOLS.index_by(&:tool_name).freeze

      # Formato atteso dal client: un solo blocco `tools` con dentro tutte le dichiarazioni.
      def self.declarations(context)
        tools = context.proposals? ? TOOLS + WRITE_TOOLS : TOOLS
        [ { functionDeclarations: tools.map(&:declaration) } ]
      end

      # Un nome sconosciuto non solleva: il modello può inventarselo, e la conversazione deve
      # proseguire dicendoglielo invece di morire.
      def self.run(name:, args:, context:)
        tool = BY_NAME[name.to_s] || (WRITE_TOOLS.find { |t| t.tool_name == name.to_s } if context.proposals?)
        return { error: "Attrezzo sconosciuto: #{name}." } if tool.nil?

        tool.new(context: context).call(args || {})
      end
    end
  end
end
