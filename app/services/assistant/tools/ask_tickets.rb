# frozen_string_literal: true

module Assistant
  module Tools
    # Domanda di SENSO sui ticket ("cosa sappiamo del login lento?"): involucro sottile sul RAG che
    # già esiste (Ticketing::AskTickets — ricerca semantica, rerank, risposta con citazioni verificate).
    #
    # Qui non si reimplementa nulla: si passa lo scope congelato e si traduce l'esito in un Hash
    # piccolo. Se il retrieval non trova niente sopra soglia il RAG risponde `insufficient` SENZA
    # chiamare il modello: lo riportiamo così com'è, perché "non ne so abbastanza" è una risposta
    # onesta e va detta, non mascherata da silenzio. Stessa regola per il guasto: se la ricerca
    # semantica è giù o spenta, l'errore ARRIVA al modello, che lo dice a chi ha chiesto.
    class AskTickets < Base
      def self.declaration
        { name: "ask_tickets",
          description: "Searches tickets by MEANING and answers questions about their content " \
                       "(e.g. 'what do we know about the slow login?', 'are there known payment problems?'). " \
                       "For lists and counts use search_tickets instead.",
          parameters: {
            type: "OBJECT",
            properties: { question: { type: "STRING", description: "The question, in natural language" } },
            required: [ "question" ]
          } }
      end

      def call(args)
        result = ::Ticketing::AskTickets.call(scope: context.tickets, question: args["question"].to_s,
                                              organization: context.organization)
        return { error: result.error.message } if result.err?

        answer = result.value
        return { insufficient: true, answer: nil } if answer.insufficient

        { answer: answer.answer,
          tickets: answer.tickets.map { |ticket| { code: ticket.code, title: ticket.title } } }
      end
    end
  end
end
