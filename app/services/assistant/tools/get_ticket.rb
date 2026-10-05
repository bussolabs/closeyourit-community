# frozen_string_literal: true

module Assistant
  module Tools
    # Il dettaglio di UN ticket citato per codice ("raccontami CYRA-279").
    #
    # Il codice viene risolto dentro il perimetro congelato, mai per id: un codice di un progetto non
    # visibile non trova nulla e lo dice, invece di leggere dati altrui.
    class GetTicket < Base
      # Commenti recenti: bastano a capire "a che punto è", senza allagare il prompt.
      RECENT_COMMENTS = 3
      # Il corpo dei ticket può essere lunghissimo: al modello serve il senso, non il testo integrale.
      BODY_CHARS = 1200
      COMMENT_CHARS = 300

      def self.declaration
        { name: "get_ticket",
          description: "Mostra un singolo ticket citato per codice (es. CYRA-279): titolo, stato, " \
                       "assegnatario, descrizione e ultimi commenti.",
          parameters: {
            type: "OBJECT",
            properties: { code: { type: "STRING", description: "Codice del ticket, es. CYRA-279" } },
            required: [ "code" ]
          } }
      end

      def call(args)
        ticket = find(args["code"])
        return { error: "Nessun ticket visibile con codice #{args['code']}." } if ticket.nil?

        { code: ticket.code, title: ticket.title,
          status: ticket.status&.display_label, priority: ticket.priority&.display_label,
          assignee: ticket.assignee&.name, project: ticket.project.key,
          created_at: ticket.created_at.to_date.to_s,
          description: ticket.description.to_s.first(BODY_CHARS),
          comments: recent_comments(ticket) }
      end

      private

      # Stessa forma del riferimento umano PROG-123 usata dalla CLI (Cli::V1::BaseController
      # #find_visible_ticket): il numero è per-progetto, quindi serve la chiave per disambiguare.
      def find(reference)
        ticket = context.find_ticket(reference)
        ticket && context.tickets.includes(:status, :priority, :assignee).find(ticket.id)
      end

      def recent_comments(ticket)
        ticket.comments.order(created_at: :desc).limit(RECENT_COMMENTS).map do |comment|
          { author: comment.author&.name, body: comment.body.to_s.first(COMMENT_CHARS) }
        end
      end
    end
  end
end
