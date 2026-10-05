# frozen_string_literal: true

module Agents
  # Un GIRO di domande di una lavorazione: quale tentativo l'ha posto, quando ha ricevuto risposta,
  # con che testo. Le domande NON stanno qui: sono righe di primo livello (CYRA-779), e da CYRA-784
  # questo è l'unico posto in cui vivono — il jsonb `questions` che le archiviava in parallelo non
  # esiste più.
  class Clarification < ApplicationRecord
    belongs_to :workflow, class_name: "Agents::Workflow", inverse_of: :clarifications
    belongs_to :attempt, class_name: "Agents::Attempt"
    belongs_to :question_comment, class_name: "Ticketing::Comment", optional: true
    belongs_to :response_comment, class_name: "Ticketing::Comment", optional: true

    # La relazione la dichiara il lato AGENTI e non il lato ticket: è il dominio degli agenti a
    # conoscere il ticket, mai il contrario (CYRA-746). `nullify` a DB: la domanda sopravvive al giro
    # che l'ha generata, come le sopravvive il commento.
    has_many :questions,
             -> { order(:position, :created_at) },
             class_name: "Ticketing::Question",
             foreign_key: :round_id,
             inverse_of: false,
             dependent: :nullify

    # Le domande che il chiamante sta per scrivere, non ancora righe. Al momento della validazione le
    # righe non possono esistere: il giro deve nascere PRIMA di loro, perché una risposta si aggancia
    # solo a una domanda più vecchia di essa. Senza questo attributo la regola del giro — quante
    # domande, e che forma hanno — non avrebbe più dove vivere, e `Ask` accetterebbe un giro vuoto:
    # un giro senza domande mette la lavorazione in attesa di una risposta che nessuno può dare.
    attr_accessor :asked

    # `on: :create` non è pignoleria: un giro si rilegge dal database per scriverci sopra la risposta
    # (`answered_at`, `response_snapshot`) e a quel punto `asked` è nil, perché le domande sono righe e
    # non un campo di questa riga. Senza il contesto, la prima risposta a un giro farebbe fallire la
    # validazione di un attributo che non esiste più — cioè una lavorazione che non riparte mai.
    validates :asked, length: { in: 1..3 }, on: :create
    validate :asked_are_simple_strings, on: :create

    private

    # Il regex della forma di comando arriva da Ticketing::Question: è la stessa regola sulla stessa
    # frase, e tenerne due copie vorrebbe dire vederle divergere.
    def asked_are_simple_strings
      valid = asked.is_a?(Array) && asked.all? do |question|
        question.is_a?(String) && question.strip.present? &&
          question.length <= Ticketing::Constants::AGENT_QUESTION_MAX_CHARS &&
          !question.match?(Ticketing::Question::COMMAND_SHAPED)
      end
      errors.add(:asked, :invalid) unless valid
    end
  end
end
