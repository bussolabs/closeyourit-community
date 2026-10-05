# frozen_string_literal: true

module Assistant
  module Tools
    # Elenca i progetti visibili. È quasi sempre il PRIMO attrezzo di una catena: serve al modello
    # per sapere che chiavi esistono davvero prima di cercare altrove, così una chiave storpiata
    # ("ci era") non diventa una ricerca a vuoto ma viene riconosciuta come CYRA.
    class ListProjects < Base
      def self.declaration
        { name: "list_projects",
          description: "Elenca i progetti che l'utente può vedere, con la loro chiave e il nome. " \
                       "Usalo per primo quando l'utente nomina un progetto in modo approssimativo, " \
                       "o quando chiede qualcosa su tutti i suoi progetti.",
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
        result[:troncato] = "Mostrati i primi #{rows.size} progetti su #{total}." if total > rows.size
        result
      end
    end
  end
end
