# frozen_string_literal: true

# Domanda di un ticket per la CLI (CYRA-783), con le sue risposte accanto.
#
# `additionalProperties` NON è chiuso qui, al contrario di `agent-clarification/v1`: quel contratto ha
# già dimostrato che una forma chiusa costa una versione nuova per ogni campo, e che un campo in più
# arrivato a un lettore `.strict()` non dà un errore — dà uno stato illeggibile e una coda ferma in
# silenzio. Qui i campi si aggiungono in coda, e chi legge ignora quelli che non conosce.
#
# `state` è calcolato, non una colonna: chi legge da fuori non deve dedurre «aperta» dall'assenza di
# due date. `blocking` da solo non basta a dire che il ticket è fermo — lo è solo finché la domanda è
# aperta.
class QuestionSerializer < ApplicationSerializer
  attributes :id, :ticket_id, :body, :blocking, :position, :created_at, :answered_at, :closed_at

  attribute(:audience) { |question| question.audience }
  attribute(:origin) { |question| question.origin }
  attribute(:author) { |question| question.author&.name }
  attribute(:closed_by) { |question| question.closed_by&.name }
  attribute(:state) do |question|
    if question.answered_at? then "answered"
    elsif question.closed_at? then "withdrawn"
    else "open"
    end
  end
  # CYRA-1033 — the proposed answers of a choice question (empty for a plain one); `choice` on an
  # answer is the 1-based number that was picked, null when the answer was typed.
  attribute(:options) { |question| question.choice_options }
  attribute(:answers) do |question|
    question.answers.map do |answer|
      {
        id: answer.id,
        body: answer.body,
        author: answer.author&.name,
        covers_round: answer.covers_round,
        choice: answer.choice_index,
        created_at: answer.created_at
      }
    end
  end
end
