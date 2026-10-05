# frozen_string_literal: true

module Ticketing
  # Che cos'è, davvero, un commento storico (CYRA-222). Serve alla compattazione: un resoconto va
  # spostato in una versione del resoconto, una domanda di chiarimento no (le domande hanno già casa
  # nelle righe di primo livello, duplicarle sarebbe rumore), un commento già corto non si tocca.
  #
  # PORO puro e senza scritture: è la decisione più delicata della migrazione — classificare male
  # significa spostare nel posto sbagliato il testo di qualcuno — quindi deve essere testabile da
  # sola, senza far girare né il job né il rake.
  class CommentShape < ApplicationService
    # Il marker che Agents::Clarifications::Ask scriveva fino a CYRA-784. Non si scrive più, ma resta
    # qui: questo servizio classifica commenti STORICI, e l'archivio è pieno di righe che ce l'hanno.
    # Toglierlo farebbe classificare come resoconto una domanda posta prima di CYRA-215, e il testo
    # finirebbe spostato nel posto sbagliato.
    #
    # NON è il regex di Ticketing::Comment#automation_generated? (`closeyourit-automation:`), che marca
    # tutt'altro: confonderli classificherebbe come domanda un resoconto marcato dall'automazione.
    QUESTION_MARKER = %r{<!--\s*closeyourit-autopilot:waiting:v1}i

    def initialize(comment:, question_comment_ids: nil)
      @comment = comment
      @question_comment_ids = question_comment_ids
    end

    def call
      return :short if @comment.body.to_s.length <= Ticketing::Constants::COMMENT_MAX_CHARS
      return :question if question?

      :report
    end

    private

    # La foreign key è il segnale PRIMARIO perché è esatto. Il marker è il fallback per le righe
    # scritte prima di CYRA-215, quando question_comment era sempre nil (vedi il commento in
    # Ticketing::AddComment#capture_clarification_response).
    def question?
      question_comment_ids.include?(@comment.id) || @comment.body.to_s.match?(QUESTION_MARKER)
    end

    # Passare l'insieme dall'esterno è l'uso normale: la migrazione lo calcola una volta per ticket
    # invece di fare una query per commento. Senza, il PORO resta comunque autonomo.
    def question_comment_ids
      @question_comment_ids ||= Agents::Clarification.where(question_comment_id: @comment.id)
                                                     .pluck(:question_comment_id)
    end
  end
end
