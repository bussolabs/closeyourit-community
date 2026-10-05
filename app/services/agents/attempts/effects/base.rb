# frozen_string_literal: true

module Agents
  module Attempts
    # Cosa SUCCEDE quando una consegna passa: un pezzo per fase, risolto da Agents::PhaseProfile#effect.
    # Prima erano cinque `apply_*` dentro Attempts::Deliver, e aggiungere una fase voleva dire aprire
    # per intero il file più delicato del sistema (CYRA-741).
    #
    # Il confine: qui NON si valida niente e non si decide se una consegna è accettabile — quando si
    # arriva a queste righe il contratto è già passato (Attempts::DeliveryContract) e il tentativo è
    # approvato. Qui resta da eseguire, non da giudicare.
    module Effects
      # La parte comune: il reset della serie di «non riesco a guardare» e il blocco chiesto
      # dall'agente, che valgono per QUALUNQUE fase. Ogni fase implementa `apply!` e, se ha qualcosa
      # da far partire dopo il commit, `after_commit`.
      class Base
        def initialize(attempt:, host:, payload:)
          @attempt = attempt
          @host = host
          @payload = payload
        end

        # Gira DENTRO la transazione della consegna, con ticket, lavorazione, progetto e host già
        # sotto lock (Attempts::Deliver#lock_scope!).
        def call
          reset_unreachable_streak!
          apply!
        end

        # Cosa parte DOPO il commit, e solo se la consegna è andata a buon fine. Sta fuori dalla
        # transazione perché sono job che leggono lo stato scritto qui: dentro girerebbero su righe
        # non ancora visibili, o terrebbero righe bloccate per la durata di una chiamata di rete.
        def after_commit; end

        private

        attr_reader :attempt, :host, :payload

        def apply! = raise(NotImplementedError, "#{self.class} deve dire cosa succede alla sua fase")

        def workflow = @attempt.workflow

        def result_state = @payload.dig("result", "state")

        # Attore degli effetti host-first: il service account snapshottato sul tentativo (immutabile, = SA
        # dell'host al claim) è l'identità operativa corretta per l'audit; fallback al SA corrente dell'host.
        def attempt_author
          @attempt.service_account || @attempt.host&.service_account
        end

        # CYRA-598 — la macchina dichiara di non poter andare avanti.
        #
        # Due esiti diversi, e la differenza conta più di quanto sembri.
        #
        # `needs_decision` (anche quando `causa` è assente: è il default sicuro) ferma la lavorazione
        # subito e la fa comparire fra quelle che aspettano una decisione, col motivo scritto
        # dall'agente. Chiamare una persona che non serviva costa un'occhiata; non chiamarla quando
        # serviva ferma la lavorazione per sempre.
        #
        # `unreachable` è un'altra cosa, e trattarla come la prima era il difetto: «non sono riuscito a
        # guardare» non è «serve una persona». Il servizio esterno non ha risposto — riprovare è la
        # cosa giusta, e chiamare qualcuno per un servizio che tornerà su da solo lo abitua a ignorare
        # le chiamate. La fase torna in coda e la lavorazione riprova; solo oltre il tetto chiama.
        #
        # Il conteggio è suo e non può essere quello dei tentativi bocciati: questa consegna è un
        # tentativo APPROVATO — il formato è valido e il contenuto è onesto — quindi di bocciature non
        # ne produce nessuna e il tetto esistente non la vedrebbe mai passare.
        def block_from_agent!
          reason = @payload.dig("result", "failure", "summary").presence ||
                   @payload.dig("result", "reason").presence || "agent_blocked: nessun motivo dichiarato"

          return block!(reason) unless unreachable?

          count = workflow.unreachable_count + 1
          workflow.update!(unreachable_count: count)
          return block!("unreachable: #{@attempt.phase} non leggibile #{count} volte — #{reason}") \
            if count >= Agents::Constants::PHASE_UNREACHABLE_LIMIT

          # Sotto il tetto: la fase torna in coda. Senza questo la lavorazione resterebbe scritta come
          # in corso — il claim ha già segnato <fase>_started_at — e non riproverebbe mai.
          workflow.reopen_execution_phase!(@attempt.phase)
        end

        # `causa` è opzionale, e assente vale needs_decision.
        def unreachable?
          failure = @payload.dig("result", "failure")
          return failure["retryable"] == true if failure.is_a?(Hash)

          @payload.dig("result", "causa") == "unreachable"
        end

        def block!(reason)
          Agents::Workflows::Block.call(
            workflow: workflow, phase: @attempt.phase, kind: "agent_blocked", reason: reason
          )
        end

        # Il contatore dei «non riesco a guardare» conta quelli DI FILA, non quelli di sempre.
        #
        # Senza questo azzeramento il conteggio è cumulativo per tutta la vita della lavorazione: due
        # letture fallite a settembre, una consegna riuscita, e il primo inciampo di ottobre — che è il
        # primo, non il terzo — farebbe scattare il tetto e chiamerebbe una persona per niente. È il
        # contrario di quello che il tetto deve fare: distinguere un inciampo da un guasto.
        #
        # Sta qui, prima dell'effetto, perché vale per QUALUNQUE consegna valida che non dichiari
        # `unreachable`, in qualunque fase: se la macchina è riuscita a guardare, la serie è rotta.
        def reset_unreachable_streak!
          return if unreachable?
          return if workflow.unreachable_count.zero?

          workflow.update!(unreachable_count: 0)
        end
      end
    end
  end
end
