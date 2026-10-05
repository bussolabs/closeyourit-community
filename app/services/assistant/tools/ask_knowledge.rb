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
          description: "Cerca nella knowledge base (note, decisioni, guide) e risponde a domande su " \
                       "come funziona qualcosa, perché è stata presa una decisione, o come si fa una " \
                       "procedura. Per lo stato del lavoro usa invece gli attrezzi sui ticket.",
          parameters: {
            type: "OBJECT",
            properties: { question: { type: "STRING", description: "La domanda, in linguaggio naturale" } },
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
