# frozen_string_literal: true

# Stato del ciclo di chiarimenti di un ticket per la CLI (CYRA-221). Serializza lo snapshot di
# Agents::Clarifications::State, non un record: è una lettura calcolata, non una riga.
#
# Sostituisce il ri-parsing dei commenti che skill e automator fanno oggi col regex del marker. Il
# LIMITE di giri non compare: quando escalare è policy del chiamante, qui ci sono solo i fatti.
class ClarificationStateSerializer < ApplicationSerializer
  attributes :state, :cycles, :has_reply

  attribute(:rounds) do |snapshot|
    snapshot.rounds.map do |round|
      {
        cycle: round.cycle,
        questions: round.questions,
        response: round.response,
        answered_at: round.answered_at,
        created_at: round.created_at
      }
    end
  end
end
