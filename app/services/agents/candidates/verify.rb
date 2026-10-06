# frozen_string_literal: true

module Agents
  module Candidates
    # CYRA-614 — il sistema apre la proposta con le sue mani, mette per iscritto quale codice c'è
    # dentro, e legge l'esito dei controlli automatici PROPRIO su quel codice.
    #
    # Prima, quando la macchina diceva «ho finito», il lavoro compariva subito fra le cose da
    # revisionare: nessuno aveva guardato se la proposta esistesse, quale codice contenesse, se i
    # controlli fossero passati. A chi approva veniva chiesto di dire sì sulla parola della stessa
    # macchina che aveva fatto il lavoro.
    #
    # Quattro esiti, tenuti distinti apposta perché portano a quattro cose diverse:
    #
    #   verified_passing         controlli verdi → il lavoro arriva davanti a una persona
    #   verified_none_configured ho guardato e di controlli non ce n'è → arriva, con la riga rossa
    #   unreachable              non sono riuscito a guardare → NON arriva, non chiede niente, riprova
    #   verified_failing         controlli rossi → la lavorazione si ferma e chiama una persona
    #
    # `unreachable` e `verified_none_configured` sono la coppia che non va mai confusa: la seconda è
    # una risposta, la prima è l'assenza di una risposta. Se finissero nella stessa casella, un guasto
    # di rete passerebbe come «nessun controllo configurato», cioè come sano.
    #
    # Ogni esito è uno STATO SCRITTO sulla riga, mai un'eccezione: un job che solleva ritenta tre
    # volte e poi tace, e il silenzio qui è indistinguibile da «tutto a posto».
    class Verify < ApplicationService
      # Quanto si aspetta prima di dire «di controlli non ce ne sono». Un elenco vuoto sul commit
      # appena spinto quasi sempre significa «non sono ancora partiti»: rispondere subito
      # `verified_none_configured` farebbe passare come non-verificato un lavoro che i controlli ce
      # li ha eccome.
      GRACE_WINDOW = 3.minutes
      # Ogni quanto tornare a guardare una riga che aspetta. Non un minuto: i controlli remoti durano
      # minuti, e ripassare più spesso è solo traffico.
      RETRY_EVERY = 1.minute

      # Le conclusioni che un controllo può avere e che valgono come rosse. `nil` non c'è: un
      # controllo senza conclusione è ancora in corso, e va aspettato.
      FAILING_CONCLUSIONS = %w[FAILURE TIMED_OUT ACTION_REQUIRED].freeze
      # CYRA-1005 — cancelled or never started: GitHub gave no verdict on the code (no runner, an outage).
      # It still stops, since nothing restarts those checks, but as checks_not_run: re-run them, do not fix code.
      NOT_RUN_CONCLUSIONS = %w[CANCELLED STARTUP_FAILURE].freeze
      FAILING_STATUS_STATES = %w[FAILURE ERROR].freeze

      def initialize(candidate:, client: nil, now: Time.current)
        @candidate = candidate
        @client = client
        @now = now
      end

      def call
        return Result.ok(@candidate) unless @candidate.state.in?(Agents::DeliveryCandidate::RETRYABLE_STATES)

        repository = @candidate.repository
        return reject!("repository_not_linked") if repository.nil?

        state = read_pull_request(repository)
        return state if state.is_a?(Result)

        apply!(state)
      rescue Github::Client::Error => e
        classify(e)
      end

      private

      def client = @client ||= Github::Client.new

      # CYRA-618 — a decidere se chiamare una persona è lo STATO della risposta, non la classe
      # dell'errore. `Github::Client::Error` è una sola per tutto: prima 401 e 403 finivano in
      # `unreachable`, cioè si riprovava all'infinito su una credenziale che nessun tentativo sistema —
      # e nessuno veniva avvisato.
      #
      # 5xx, timeout e 429 sono il canale rotto: si aspetta e si riprova, e non si chiama nessuno.
      # 401, 403 e 404 sono risposte autorevoli: non cambiano riprovando, e serve una persona.
      DEFINITIVE_STATUSES = %i[unauthorized forbidden not_found].freeze

      def classify(error)
        return postpone!("unreachable", error.code) unless DEFINITIVE_STATUSES.include?(error.status)

        reject!(error.status == :not_found ? "pull_request_missing" : "access_denied",
                detail: "#{error.code}: #{error.message}")
      end

      # Non si legge NIENTE dal database e niente dal rapporto dell'agente: head, base e controlli
      # arrivano tutti dalla stessa risposta. È la differenza fra «il codice che il sistema ha visto»
      # e «l'ultima cosa che c'era su quel ramo quando l'agente ha guardato».
      def read_pull_request(repository)
        client.pull_request_state(repository.github_installation_id, @candidate.repository_full_name,
                                  @candidate.number)
      end

      def apply!(state)
        return reject!("base_not_default_branch") unless base_is_default_branch?(state)

        checks = Array(state[:checks])
        return postpone!("unreachable", "checks_unknown") unless state[:checks_known]
        return postpone!("checks_running", nil, state:) if checks.any? { |c| still_running?(c) }
        return fail!(state, checks) if checks.any? { |c| failing?(c) }
        return fail!(state, checks, code: "checks_not_run") if checks.any? { |c| not_run?(c) }
        return postpone!("checks_running", nil, state:) if checks.empty? && within_grace?(state)

        pass!(state, checks)
      end

      # Il ramo di destinazione dev'essere il ramo principale del repository di destinazione, letto
      # dalla stessa risposta. Una proposta verso un ramo qualunque non è il lavoro che stiamo per
      # mettere davanti a una persona.
      def base_is_default_branch?(state)
        default_branch = state[:base_default_branch]
        default_branch.present? && state[:base_ref] == default_branch
      end

      def still_running?(check)
        check["__typename"] == "CheckRun" && check["conclusion"].nil?
      end

      def not_run?(check)
        check["__typename"] == "CheckRun" && NOT_RUN_CONCLUSIONS.include?(check["conclusion"].to_s.upcase)
      end

      def failing?(check)
        if check["__typename"] == "CheckRun"
          FAILING_CONCLUSIONS.include?(check["conclusion"].to_s.upcase)
        else
          FAILING_STATUS_STATES.include?(check["state"].to_s.upcase)
        end
      end

      def within_grace?(state)
        visto = state[:head_committed_at].presence && Time.zone.parse(state[:head_committed_at])
        visto.present? && visto > @now - GRACE_WINDOW
      rescue ArgumentError
        # Una data che non si legge non è una prova che il tempo sia passato: si aspetta.
        true
      end

      # ── I quattro esiti ─────────────────────────────────────────────────────────────────────────

      def pass!(state, checks)
        final_state = checks.empty? ? :verified_none_configured : :verified_passing
        ApplicationRecord.transaction do
          write_verdict!(state, checks, final_state)
          promote!
        end
        # CYRA-868 — con i controlli verdi la consegna va avanti da sola: di decisione per ticket ne
        # resta UNA, il piano. FUORI dalla transazione perché quel passo riapre la proposta su GitHub
        # per confrontare il codice vivo, e un HTTP là dentro terrebbe righe bloccate per la durata di
        # una rete lenta. L'esito non si propaga: «non è passata da sola» lascia il lavoro davanti a
        # una persona, e non è un guasto della verifica appena scritta.
        auto_approve! if final_state == :verified_passing
        Result.ok(@candidate)
      end

      def auto_approve!
        Agents::Workflows::AutoApprove.call(workflow: @candidate.workflow, candidate: @candidate,
                                            client: client)
      end

      def fail!(state, checks, code: "checks_failing")
        ApplicationRecord.transaction do
          write_verdict!(state, checks, :verified_failing)
          stop!(code)
        end
        Result.ok(@candidate)
      end

      # `unreachable` e `checks_running` non sono un verdetto: la riga resta com'è e si riprova. Non
      # si scrive `verified_at`, che è la firma di «qui qualcuno ha guardato ed è arrivato in fondo».
      def postpone!(final_state, code, state: nil)
        @candidate.update!(state: final_state, last_checked_at: @now,
                           next_check_at: @now + RETRY_EVERY, last_error_code: code,
                           **coordinate(state))
        Result.ok(@candidate)
      end

      # Una risposta definitiva che non passa: non si riprova, si chiama una persona.
      # CYRA-761 — il codice da solo non basta: «pull_request_missing» esce per una proposta davvero
      # assente, per un token di installazione rifiutato e per un permesso mancante. Il motivo che
      # GitHub ha dato resta scritto nel blocco, dove una persona lo legge.
      def reject!(code, detail: nil)
        ApplicationRecord.transaction do
          @candidate.update!(state: :rejected, last_checked_at: @now, next_check_at: nil,
                             last_error_code: code)
          stop!(code, detail:)
        end
        Result.ok(@candidate)
      end

      # `head_sha` e `base_ref` si congelano dalla risposta, e una volta scritti non si riscrivono:
      # `ensure_verdict_is_final` lo impedisce dal verdetto in poi.
      def coordinate(state)
        return {} if state.nil?

        { head_sha: state[:head_sha], base_ref: state[:base_ref] }
      end

      def write_verdict!(state, checks, final_state)
        @candidate.update!(state: final_state, verified_at: @now, last_checked_at: @now,
                           next_check_at: nil, last_error_code: nil,
                           checks_payload: checks, checks_count: checks.size,
                           **coordinate(state))
      end

      # Il lavoro arriva davanti a una persona. Lo spostamento del ticket sullo status di revisione
      # sta QUI e non nella consegna: è il momento in cui il sistema ha davvero guardato.
      # CYRA-622 — la parola la sceglie la proiezione fase→stato, unico posto che conosce la
      # corrispondenza: qui si scrive il fatto osservato e si lascia che la parola lo segua. Un'
      # organizzazione senza stato di revisione configurato non ferma la verifica — il fatto è stato
      # visto comunque, e fermarla vorrebbe dire buttare via il lavoro appena fatto.
      def promote!
        workflow = @candidate.workflow
        workflow.update!(candidate_verified_at: @now, review_candidate_id: @candidate.id)
        Agents::Workflows::StatusProjection.call(workflow:)
      end

      # CYRA-618 — fermarsi passa dalla porta unica, col secondo ingresso: qui di tentativi bocciati
      # non ce n'è nemmeno uno — la consegna era valida — e fabbricarne uno finto per riusare il tetto
      # farebbe contare una storia che non c'è. Il motivo porta da DOVE è stato visto.
      def stop!(code, detail: nil)
        reason = "#{code} on #{@candidate.repository_full_name}##{@candidate.number}"
        reason = "#{reason} — #{detail}" if detail.present?
        Agents::Workflows::BlockExhaustedPhase.call(
          workflow: @candidate.workflow, phase: "autopilot", source: "candidate_check", reason: reason
        )
      end
    end
  end
end
