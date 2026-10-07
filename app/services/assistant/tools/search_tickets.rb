# frozen_string_literal: true

module Assistant
  module Tools
    # Elenco FILTRATO di ticket: la domanda strutturata ("quali sono aperti su CYRA", "cosa ho in
    # carico"), non quella di senso — per quella c'è ask_tickets, che cerca per significato.
    #
    # Il filtro sullo stato passa per la CATEGORIA (Types::TicketStatus#category) e non per il code,
    # così "aperti" indica lo stesso insieme che l'utente vede nelle chip del progetto: contare per
    # code lascerebbe fuori "in revisione" e produrrebbe un numero diverso da quello a schermo.
    class SearchTickets < Base
      CATEGORIES = %w[open in_progress done].freeze

      def self.declaration
        { name: "search_tickets",
          description: "Lists the tickets of a project, filtered by status or assignee. " \
                       "Use it for questions about HOW MANY or WHICH tickets (lists, counts). " \
                       "For questions about the CONTENT of tickets use ask_tickets instead.",
          parameters: {
            type: "OBJECT",
            properties: {
              project: { type: "STRING", description: "Project key, e.g. CYRA" },
              status: { type: "STRING", enum: CATEGORIES,
                        description: "open = to do, in_progress = in progress or in review, done = done" },
              mine: { type: "BOOLEAN", description: "true for only the tickets assigned to the person asking" }
            },
            required: [ "project" ]
          } }
      end

      def call(args)
        project = context.find_project(args["project"])
        return not_visible(args["project"]) if project.nil?

        scope = filtered(project, args)
        rows = scope.includes(:status, :assignee).order(created_at: :desc).limit(MAX_ROWS).map do |ticket|
          { code: ticket.code, title: ticket.title, status: ticket.status&.display_label,
            assignee: ticket.assignee&.name }
        end

        { project: project.key, total: scope.count, showing: rows.size, tickets: rows }
      end

      private

      # Uno stato che non esiste (il modello può inventarlo, o tradurlo) NON diventa un filtro: si
      # ignora e si risponde con l'elenco intero, che è comunque un dato vero. Sollevare a metà
      # conversazione per un enum sbagliato costerebbe un giro e non aggiungerebbe niente.
      def filtered(project, args)
        scope = context.tickets.where(project_id: project.id)
        scope = scope.where(assignee_id: context.account.id) if args["mine"]
        category = args["status"].to_s.presence
        return scope unless CATEGORIES.include?(category)

        scope.joins(:status).where(types_ticket_statuses: { category: Types::TicketStatus.categories[category] })
      end
    end
  end
end
