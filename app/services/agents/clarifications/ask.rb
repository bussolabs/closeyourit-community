# frozen_string_literal: true

module Agents
  module Clarifications
    # Registra le domande di chiarimento del triage e ne annuncia UNA RIGA sul ticket.
    #
    # Le domande sono righe di primo livello (`Ticketing::Question`) e si leggono nella scheda Domande,
    # con la risposta accanto a ciascuna. Nella discussione resta una riga di servizio a lunghezza
    # fissa: un commento è un messaggio breve (tetto Ticketing::Constants::COMMENT_MAX_CHARS) e tre
    # domande da 180 caratteri non ci starebbero mai. Prima di CYRA-221 il corpo era ~716 caratteri:
    # col tetto attivo avrebbe fatto RecordInvalid dentro la transazione di Deliver, cioè 500 sulla
    # consegna e ticket fermo in progress per sempre.
    #
    # Il commento lo scrive il SERVER, non la skill. La skill gira in una sessione sandboxata dove i
    # guardrail rifiutano qualunque comando contenga `?`, graffe o espansioni (CYAU-109): una domanda
    # finisce per definizione con un punto interrogativo, quindi non esiste comando con cui postarla,
    # e le fasi read non hanno un worktree in cui scriverla su file. L'unico canale rimasto è il
    # risultato della fase, che arriva qui.
    #
    # Commento e Clarification nascono nella stessa transazione della delivery: prima erano separati e
    # una risposta umana arrivata nella finestra fra i due non trovava la Clarification a cui agganciarsi.
    #
    # CYRA-784 — la riga di servizio non porta più nessun marker in coda. Lo stato del ciclo i due
    # lettori esterni (skill di triage e automator) lo chiedono a `GET .../clarifications`, che è il
    # contratto `agent-clarification/v1`: il testo di un commento è tornato a essere solo testo.
    class Ask < ApplicationService
      # A v2 question may be `{ body, options }`: the ticket stores only the text, the proposed
      # answers stay in the attempt result. CYRA-887
      def self.texts(questions)
        Array(questions).map { |question| question.is_a?(Hash) ? (question["body"] || question[:body]) : question }
      end

      def initialize(workflow:, attempt:, questions:, author:)
        @workflow = workflow
        @attempt = attempt
        @questions = self.class.texts(questions)
        @author = author
      end

      # La transazione tiene insieme i due scritti anche quando il servizio è chiamato da solo: un
      # commento senza record chiederebbe a vuoto (nessuno riaggancerebbe la risposta), un record senza
      # commento lascia il ciclo cieco (il lettore non vede la domanda pendente e richiede da capo).
      def call
        clarification = nil
        ApplicationRecord.transaction do
          # Il giro PRIMA delle domande e del commento: Ticketing::AddComment#capture_legacy_answer
          # aggancia una risposta solo a una domanda nata prima di essa (confronto su `created_at`).
          # Nell'ordine opposto, con i due record nello stesso istante, la risposta resterebbe orfana.
          clarification = Agents::Clarification.create!(
            workflow: @workflow, attempt: @attempt, asked: @questions
          )
          write_questions!(clarification)
          comment = @workflow.ticket.comments.create!(body: body, author: @author, kind: :service)
          clarification.update!(question_comment: comment)
        end
        Result.ok(clarification)
      end

      private

      # BLOCCANTI: una domanda del triage ferma la lavorazione, ed è sempre stato così di fatto — il
      # workflow non avanzava finché non arrivava la risposta. Ora il fatto è scritto sulla riga, ed è
      # quello che la coda degli agenti guarda. `internal`: una domanda di triage parla del lavoro da
      # fare, non è materiale da mostrare a un cliente.
      #
      # `save(validate: false)`: il contratto di consegna ha già giudicato queste stringhe, e il giro
      # le ha appena rigiudicate con le stesse regole. Rigiudicarle una terza volta qui, con quelle
      # della riga, farebbe fallire la transazione di consegna su un testo già accettato — cioè una
      # lavorazione che riprova all'infinito su una consegna valida.
      def write_questions!(clarification)
        @questions.each_with_index do |body, index|
          Ticketing::Question.new(
            ticket: @workflow.ticket, round_id: clarification.id, body: body.to_s, position: index + 1,
            blocking: true, audience: :internal, origin: :agent, author: @author
          ).save(validate: false)
        end
      end

      # Il commento lo legge una persona, non la macchina: la lingua è quella di chi ha aperto il
      # ticket, come fa il fan-out delle notifiche. La lunghezza NON dipende dalle domande — è ciò che
      # tiene il corpo sotto il tetto qualunque cosa abbia chiesto il triage.
      def body
        I18n.with_locale(@workflow.ticket.reporter&.effective_locale || I18n.default_locale) do
          I18n.t("agents.clarifications.ask.service_line", count: @questions.size)
        end
      end
    end
  end
end
