# frozen_string_literal: true

module Assistant
  module Tools
    # Elenca i progetti visibili. È quasi sempre il PRIMO attrezzo di una catena: serve al modello
    # per sapere che chiavi esistono davvero prima di cercare altrove, così una chiave storpiata
    # ("ci era") non diventa una ricerca a vuoto ma viene riconosciuta come CYRA.
    class ListProjects < Base
      def self.declaration
        { name: "list_projects",
          description: "Lists the projects the user can see, with their key and name. " \
                       "Use it first when the user names a project loosely, " \
                       "or asks something about all their projects.",
          parameters: { type: "OBJECT", properties: {} } }
      end

      def call(_args)
        total = context.projects.count
        rows = context.projects.order(:key).limit(MAX_ROWS)
                      .pluck(:key, :name)
                      .map { |key, name| { key: key, name: name } }

        # `total` è il numero VERO, non quanti se ne mostrano: dire "ne hai 20" quando sono 30
        # farebbe rispondere al modello un numero sbagliato con la faccia di un dato certo. Quando
        # l'elenco è tagliato lo si dichiara, così può dirlo a chi ha chiesto.
        result = { projects: rows, total: total }
        # Live, a model read a cut list as complete and called a project that exists "not found".
        result[:troncato] = "Showing the first #{rows.size} projects of #{total}. A project missing here may still exist: " \
                            "pass its key to the tool you need." if total > rows.size
        result
      end
    end
  end
end
