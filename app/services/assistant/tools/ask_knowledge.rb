# frozen_string_literal: true

module Assistant
  module Tools
    # Domanda alla knowledge base: involucro sul RAG esistente (Knowledge::AskPages), gemello di
    # AskTickets. Le due fonti restano DISTINTE di proposito — i ticket dicono cosa sta succedendo,
    # le pagine dicono cosa abbiamo deciso e imparato — così il modello sceglie dove guardare e la
    # risposta cita la fonte giusta.
    class AskKnowledge < Base
      def self.declaration
        { name: "ask_knowledge",
          description: "Searches the knowledge base (notes, decisions, guides) and answers questions about " \
                       "how something works, why a decision was taken, or how a procedure is done. " \
                       "For the state of the work use the ticket tools instead.",
          parameters: {
            type: "OBJECT",
            properties: { question: { type: "STRING", description: "The question, in natural language" } },
            required: [ "question" ]
          } }
      end

      def call(args)
        result = ::Knowledge::AskPages.call(scope: context.knowledge_pages, question: args["question"].to_s,
                                            organization: context.organization)
        return { error: result.error.message } if result.err?

        answer = result.value
        return { insufficient: true, answer: nil } if answer.insufficient

        { answer: answer.answer,
          pages: answer.pages.map { |page| { title: page.title } } }
      end
    end
  end
end
