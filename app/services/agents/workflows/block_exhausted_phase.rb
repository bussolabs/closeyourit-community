# frozen_string_literal: true

module Agents
  module Workflows
    # Tetto ai tentativi di UNA fase (CYRA-218, esteso da CYRA-504). Esaurito il budget la lavorazione
    # si ferma e chiama una persona. Ritorna true se la lavorazione è ferma (blocco scritto ora o già
    # presente), false se ha ancora budget: è ciò su cui il chiamante decide se rimetterla in coda.
    #
    # Perché è un service e non un metodo privato di Deliver: viveva lì, e lì passa solo chi CONSEGNA
    # qualcosa. I due modi di finire senza consegnare — ReportFailure (`failed`) e MarkStale (`stale`,
    # lease scaduto: host morto oppure consegna mai tentata) — non lo attraversavano, quindi non
    # contavano nulla. Il 2026-08-09 CYRA-298 ha rifatto la stessa pianificazione 31 volte senza che il
    # tetto se ne accorgesse: l'agente si fermava ogni volta correttamente, ma quel rifiuto non è un
    # formato consegnabile e nessun timestamp si muoveva.
    #
    # `stale` da guasto (host morto) e `stale` da resa (consegna mai tentata) arrivano identici al
    # server e non sono distinguibili coi dati di oggi: contano allo stesso modo — un host che muore due
    # volte di fila sulla stessa fase è comunque una lavorazione da guardare.
    #
    # Il motivo è una riga di AUDIT, non la frase che leggerà una persona: resta in una lingua sola e in
    # forma stabile, così è confrontabile fra righe e nel tempo. La UI compone il testo localizzato dai
    # campi strutturati (blocked_phase e il conteggio).
    class BlockExhaustedPhase < ApplicationService
      COUNTED_STATUSES = %w[review_failed failed stale].freeze

      # CYRA-618 — due ingressi, una porta sola.
      #
      # Il primo prende un `attempt:` e conta: è il tetto ai tentativi. Il secondo non ne ha uno, e non
      # è una scorciatoia — i verificatori del server non producono tentativi, e fabbricarne di finti
      # per riusare il primo farebbe contare una storia che non c'è. Passano comunque tutti e due da
      # `Block`, così i quattro campi del blocco si scrivono in un punto solo.
      #
      # `source:` finisce nel motivo perché «si è fermata» e «si è fermata per questo, visto da qui»
      # sono due cose diverse per chi va a leggere l'archivio fra un mese.
      # CYRA-624 — `kind:` dice DOVE il fatto è stato visto, e da lì dipende la frase che legge chi
      # deve decidere. Il default resta quello di ieri: i verificatori delle proposte non cambiano.
      def initialize(attempt: nil, workflow: nil, phase: nil, reason: nil, source: nil,
                     kind: "candidate_check")
        @attempt = attempt
        @workflow = workflow || attempt&.workflow
        @phase = phase || attempt&.phase
        @reason = reason
        @source = source
        @kind = kind
      end

      def call
        raise ArgumentError, "serve un attempt oppure workflow+phase+reason" if invalid_input?
        return true if @workflow.blocked_at?
        return block_observed_fact! if @attempt.nil?

        count = failures_on_phase(@workflow).count
        return false if count < Agents::Constants::PHASE_REVIEW_LIMIT

        # La scrittura passa da Block: due punti che scrivono gli stessi quattro campi divergono, e
        # il campo che divergerebbe per primo è proprio `blocked_kind`, da cui dipende la frase che
        # legge chi deve decidere.
        Agents::Workflows::Block.call(
          workflow: @workflow, phase: @phase, kind: "attempt_limit",
          reason: "attempt_limit: #{@phase} failed #{count} times"
        )
      end

      private

      def invalid_input?
        @workflow.nil? || @phase.blank? || (@attempt.nil? && @reason.blank?)
      end

      # Un fatto osservato che non torna: non si conta niente, si ferma e si chiama una persona. Il
      # motivo porta da DOVE è stato visto, perché fra un mese «si è fermata» da solo non basta.
      def block_observed_fact!
        Agents::Workflows::Block.call(
          workflow: @workflow, phase: @phase, kind: @kind,
          reason: [ @source, @reason ].compact_blank.join(": ")
        )
      end

      # Solo i fallimenti DOPO l'ultimo sblocco: gli attempt sono audit immutabile e restano lì per
      # sempre, quindi contando tutta la storia il tentativo concesso da un "riprova" sarebbe l'unico —
      # chiuso quello, il conteggio è già oltre il tetto e il blocco torna subito.
      def failures_on_phase(workflow)
        failures = workflow.attempts.where(phase: @phase, status: COUNTED_STATUSES)
        return failures unless workflow.review_budget_from?

        failures.where(created_at: workflow.review_budget_from..)
      end
    end
  end
end
