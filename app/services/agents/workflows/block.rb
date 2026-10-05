# frozen_string_literal: true

module Agents
  module Workflows
    # Fermare una lavorazione e chiamare una persona. È il primitivo: scrive i quattro campi del
    # blocco e non fa altro.
    #
    # Perché non basta BlockExhaustedPhase, che pure esisteva. Quello prende un `attempt:` e gli
    # serve davvero — legge `attempt.phase` per sapere quale fase fermare e conta i tentativi di
    # quella fase per decidere se il budget è finito. Sono due cose che un blocco dichiarato
    # dall'agente non ha: la fase gliela dice il chiamante, e di tentativi bocciati non ne esiste
    # nemmeno uno, perché una consegna che dice «questo non si può fare» è una consegna VALIDA —
    # l'attempt si chiude `approved`. Passargli un attempt finto per riusarlo avrebbe fatto contare
    # una storia che non c'è.
    #
    # `kind` non è decorazione. Distingue chi ha fermato la lavorazione, e da lì dipende la frase che
    # legge chi deve decidere: quella del tetto nomina la revisione e conta le bocciature, e su un
    # blocco d'agente quel conteggio è zero — stamperebbe «La revisione ha respinto autopilot 0 volte
    # di fila». Falso, nel posto peggiore.
    #
    # Idempotente per scelta: una lavorazione già ferma resta ferma col motivo che aveva. Il primo
    # motivo è quello vero; i successivi sono conseguenze del primo.
    class Block < ApplicationService
      # CYRA-614 — `candidate_check`: il sistema è andato a guardare la proposta e ha trovato qualcosa
      # che non va (controlli rossi, proposta assente, ramo di destinazione sbagliato, repository non
      # collegato). Non è il tetto dei tentativi e non è un blocco dichiarato dall'agente: la frase da
      # leggere è un'altra, e senza un `kind` suo verrebbe raccontato come uno dei due.
      # CYRA-624 — `release_probe`: il rilascio non si è visto in piedi. È un momento diverso dal
      # controllo della proposta, e chiamarlo con le sue parole manderebbe a cercare nel posto sbagliato.
      # CYRA-871 — `held_by_person`: il CTO ha fermato un rilascio prima della produzione.
      KINDS = %w[attempt_limit agent_blocked candidate_check release_probe held_by_person].freeze

      def initialize(workflow:, phase:, reason:, kind:)
        @workflow = workflow
        @phase = phase
        @reason = reason
        @kind = kind
      end

      def call
        raise ArgumentError, "kind sconosciuto: #{@kind}" unless KINDS.include?(@kind)
        return true if @workflow.blocked_at?

        @workflow.update!(blocked_at: Time.current, blocked_phase: @phase,
                          blocked_kind: @kind, blocked_reason: @reason)
        true
      end
    end
  end
end
