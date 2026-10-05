# frozen_string_literal: true

# Round di chiarimento: le domande che una lavorazione pone quando le manca una decisione.
#
# `questions` è un transient e non una colonna: da CYRA-784 le domande sono righe di primo livello
# (`Ticketing::Question`) e il giro le conta soltanto. Le righe nascono qui con `save(validate: false)`
# come le scrive Agents::Clarifications::Ask — un testo già accettato dal giro non si rigiudica con le
# regole della riga.
FactoryBot.define do
  factory :agent_clarification, class: "Agents::Clarification" do
    transient do
      questions { [ "Quale delle due strade preferisci?" ] }
    end

    workflow factory: :agent_workflow
    attempt { create(:agent_attempt, workflow: workflow) }
    asked { questions }

    after(:create) do |clarification, evaluator|
      ticket = clarification.workflow.ticket
      evaluator.questions.each_with_index do |body, index|
        Ticketing::Question.new(
          ticket: ticket, round_id: clarification.id, body: body, position: index + 1,
          blocking: true, audience: :internal, origin: :agent, author: ticket.reporter
        ).save(validate: false)
      end
    end
  end
end
