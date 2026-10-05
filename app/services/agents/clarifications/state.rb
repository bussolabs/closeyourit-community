# frozen_string_literal: true

module Agents
  module Clarifications
    # Lo stato del ciclo di chiarimenti di una lavorazione, letto dal DATABASE (CYRA-221).
    #
    # Fino a qui lo stato viveva nel testo dei commenti: tre implementazioni di un regex in tre
    # repository (server, skill di triage, automator) che ri-parsavano la discussione per sapere se
    # una domanda era pendente e a che giro. Un commento riformattato o cancellato cambiava lo stato
    # di una lavorazione — e la copia divergente di un lettore lo cambiava solo per lui.
    #
    # PORO puro e senza scritture, come Ticketing::CommentShape: è la risposta di un endpoint letto da
    # due repository esterni, deve essere testabile senza far girare né la coda né HTTP.
    #
    # Il LIMITE di cicli non sta qui. Il server espone i fatti (quanti giri, se c'è risposta, se
    # qualcuno ha già escalato); quando escalare è una policy del chiamante e vive già in
    # `decideClarification` (DEFAULT_CLARIFICATION_LIMIT). Duplicarla qui vorrebbe dire due numeri in
    # due repository che un giorno divergono, e nessuno se ne accorge finché un ticket non si blocca.
    class State < ApplicationService
      # Struttura immutabile: la risposta di questo servizio finisce in un serializer e in un
      # contratto versionato, non è uno stato da mutare.
      Round = Data.define(:cycle, :questions, :response, :answered_at, :created_at)
      Snapshot = Data.define(:state, :cycles, :has_reply, :rounds)

      def initialize(workflow:)
        @workflow = workflow
      end

      def call
        Snapshot.new(state: state, cycles: rounds.size, has_reply: has_reply?, rounds: rounds)
      end

      private

      # Nessun workflow = nessuna lavorazione avviata: `ready`, cioè "niente da aspettare", che è
      # esattamente ciò che un lettore deve concludere per un ticket mai lavorato.
      #
      # `escalated` è `blocked_at` di CYRA-218, non un campo suo: "la lavorazione si è fermata e
      # chiama una persona" è già quel dato, con la sua UI e il suo "riprova" (Agents::Workflows::Unblock).
      # Una colonna gemella sarebbe un secondo stato di arresto da tenere allineato al primo — e il
      # giorno che divergono, un ticket resta fermo con la pagina che lo dà per attivo.
      def state
        return "ready" if @workflow.blank?
        return "escalated" if @workflow.blocked_at?
        return "waiting" if rounds.any? { |round| round.answered_at.blank? }

        "ready"
      end

      # L'ULTIMO giro, non uno qualsiasi: una risposta vecchia a una domanda vecchia non dice niente
      # sul giro in corso, e un lettore che la leggesse come "ha risposto" riprenderebbe una
      # lavorazione ancora in attesa.
      def has_reply?
        rounds.last&.answered_at.present?
      end

      # Il numero di giro è la POSIZIONE cronologica: contarla qui invece di rileggerla dal testo dei
      # commenti è tutto il punto di questo servizio, ed è ciò che ha permesso a CYRA-784 di spegnere
      # il marker senza che nessun lettore perdesse il conto.
      def rounds
        @rounds ||= begin
          records = @workflow.blank? ? [] : @workflow.clarifications.order(:created_at)
                                                     .includes(questions: %i[answers resolved_answer])
          records.each_with_index.map do |clarification, index|
            Round.new(
              cycle: index + 1,
              questions: questions_of(clarification),
              response: response_of(clarification),
              answered_at: clarification.answered_at,
              created_at: clarification.created_at
            )
          end
        end
      end

      # CYRA-784 — le domande si leggono dalle righe di primo livello, e da lì soltanto: l'archivio
      # jsonb che le teneva in parallelo non esiste più.
      #
      # `first(3)`: il contratto dichiara al massimo tre domande per giro. Il tetto lo tiene
      # Agents::Clarification sulle domande in arrivo, ma una riga può essere aggiunta a un giro anche
      # da altrove — qui sarebbe un payload che il lettore esterno rifiuta in blocco, e con esso
      # l'intera coda.
      def questions_of(clarification)
        clarification.questions.map(&:body).reject(&:blank?).first(3)
      end

      # Lo storico si serve VERBATIM: `response_snapshot` è il testo che i due repository esterni
      # hanno già letto, e ricomporlo sarebbe il modo di cambiarlo senza volerlo. Solo dove non c'è —
      # cioè per le risposte scritte dopo il passaggio alle righe nuove — si compone, e nella forma
      # numerata che il lettore vedeva prima (`Agents::Clarifications::Answer`): la forma è parte del
      # contratto quanto i nomi dei campi.
      def response_of(clarification)
        return clarification.response_snapshot if clarification.response_snapshot.present?

        rows = clarification.questions.each_with_index.filter_map do |question, index|
          text = question.resolved_answer&.body.presence || question.answers.first&.body
          "#{index + 1}. #{text}" if text.present?
        end
        rows.presence&.join("\n")
      end
    end
  end
end
