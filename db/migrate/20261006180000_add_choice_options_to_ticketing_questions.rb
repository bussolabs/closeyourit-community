# frozen_string_literal: true

# Choice questions (CYRA-1033): the question keeps the proposed answers it was asked with, and an
# answer records which one was clicked. Before, the options lived only in the attempt result and
# only the approvals queue read them. Existing agent questions get their options back from there.
class AddChoiceOptionsToTicketingQuestions < ActiveRecord::Migration[8.1]
  def up
    add_column :ticketing_questions, :options, :jsonb
    add_column :ticketing_answers, :choice_index, :integer

    execute <<~SQL.squish
      UPDATE ticketing_questions AS questions
      SET options = attempts.result -> 'questions' -> (questions.position - 1) -> 'options'
      FROM agents_clarifications AS rounds
      JOIN agents_attempts AS attempts ON attempts.id = rounds.attempt_id
      WHERE questions.round_id = rounds.id
        AND jsonb_typeof(attempts.result -> 'questions' -> (questions.position - 1)) = 'object'
        AND jsonb_typeof(attempts.result -> 'questions' -> (questions.position - 1) -> 'options') = 'array'
    SQL
  end

  def down
    remove_column :ticketing_answers, :choice_index
    remove_column :ticketing_questions, :options
  end
end
