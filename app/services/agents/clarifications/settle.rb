# frozen_string_literal: true

module Agents
  module Clarifications
    # Chiude un giro di chiarimenti con le risposte arrivate (CYRA-781).
    #
    # È il punto UNICO in cui una risposta chiude un giro e rimette la lavorazione in coda al triage.
    # Prima erano due, con regole diverse: il form della scheda Automazione componeva un commento
    # numerato, e `Ticketing::AddComment` agganciava per prossimità temporale qualunque commento umano
    # successivo. Due strade per lo stesso fatto sono due comportamenti il giorno che una cambia.
    #
    # Le risposte arrivano per POSIZIONE (la prima domanda, la seconda, la terza), che è come il form
    # le indicizza e come il giro le ha numerate. I buchi restano buchi: chi risponde a due domande su
    # tre non deve inventarsi una riga per la terza.
    class Settle < ApplicationService
      include Agents::Workflows::ConcludedTicketGate

      # `origin: :agent` marks the supporter's answers (CYAU-235): a person's answer stays :human.
      def initialize(clarification:, author:, answers:, covers_round: false, response_comment: nil, origin: :human)
        @clarification = clarification
        @origin = origin
        @author = author
        @answers = Array(answers)
        @covers_round = covers_round
        @response_comment = response_comment
      end

      def call
        rows = entries
        return blank if rows.empty?
        # CYRA-630 — su un ticket concluso la risposta si registra ma non rimette in coda niente:
        # lasciarla ripartire vorrebbe dire far riprendere il lavoro, il giorno che qualcuno riapre il
        # ticket, da uno stato che nessuno ha voluto.
        return concluded_ticket if concluded_ticket?

        ApplicationRecord.transaction do
          rows.each { |_position, question, body, choice| answer!(question, body, choice) }
          close_round!(rows)
        end
        Result.ok(@clarification)
      end

      private

      def workflow = @clarification.workflow

      # [[posizione, domanda, testo, scelta], …] nell'ordine delle domande del giro. An answer is either
      # the text or `{ body:, choice: }` when a proposed answer was clicked (CYRA-1033).
      #
      # Le righe di primo livello sono l'unica sorgente da CYRA-784. Un giro che non ne ha nemmeno una
      # non ha niente da chiudere: prima ci si arrivava con l'archivio jsonb, che chiudeva il giro
      # senza una riga a cui appendere la risposta, e quel caso non esiste più.
      #
      # Una domanda già risposta si salta: il momento in cui ha smesso di aspettare è uno solo.
      # A withdrawn one too: Answer refuses it, and the round must not close on a refused answer. CYRA-1002
      def entries
        questions.each_with_index.filter_map do |question, index|
          entry = @answers[index]
          body = (entry.is_a?(Hash) ? entry[:body] : entry).to_s.strip
          next if body.blank? || question.answered_at.present? || question.closed_at.present?

          [ index + 1, question, body, (entry[:choice] if entry.is_a?(Hash)) ]
        end
      end

      # Ticket and project preloaded: answering checks the author's organization once per question. CYRA-887
      def questions
        @questions ||= @clarification.questions.includes(ticket: :project).order(:position, :created_at).to_a
      end

      def answer!(question, body, choice)
        Ticketing::Questions::Answer.call(
          question: question, author: @author, body: body, covers_round: @covers_round, choice_index: choice,
          origin: @origin
        )
      end

      # Il giro si chiude alla PRIMA risposta, non quando tutte le domande ne hanno una: è la
      # semantica di sempre (il primo commento umano chiudeva il giro), e cambiarla lascerebbe in
      # attesa per sempre le lavorazioni che oggi ripartono.
      #
      # `response_snapshot` resta scritto, nella forma numerata di prima: è il testo che il contratto
      # verso i due repository esterni serve verbatim, e comporlo qui una volta è ciò che lo rende
      # indipendente da come le righe verranno lette domani.
      def close_round!(rows)
        workflow.lock!
        return if @clarification.reload.answered_at?

        @clarification.update!(answered_at: Time.current, response_snapshot: snapshot(rows),
                               response_comment: @response_comment)
        workflow.update!(triage_requested_at: Time.current, triage_started_at: nil)
      end

      # La numerazione dice A QUALE domanda risponde ogni riga, e ha senso solo quando chi ha risposto
      # una domanda l'ha nominata. Un commento libero copre il giro intero: numerarlo aggiungerebbe un
      # «1. » davanti al testo di qualcuno — e quel testo è ciò che il contratto serve verbatim ai due
      # repository esterni, che lo mostrano a una persona.
      def snapshot(rows)
        return rows.first[2] if @covers_round

        rows.map { |position, _question, body| "#{position}. #{body}" }.join("\n")
      end

      def blank
        Result.err(AppError.new(I18n.t("member.tickets.automation.questions.errors.blank"),
                                code: "R422-CLARIFICATION-001"))
      end
    end
  end
end
