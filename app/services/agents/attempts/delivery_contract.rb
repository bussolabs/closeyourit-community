# frozen_string_literal: true

module Agents
  module Attempts
    # La barriera server della consegna: dice SE un rapporto è accettabile, e non applica mai niente.
    # Estratta da Attempts::Deliver (CYRA-741), dove convive con gli effetti di ogni fase rendeva il
    # file più delicato del sistema anche il più lungo.
    #
    # Non persiste niente da sé — nemmeno sul ramo bocciato: chi chiama registra il tentativo come
    # `review_failed` per QUALUNQUE esito di validazione, e farlo anche qui vorrebbe dire due
    # scritture con due verità diverse.
    class DeliveryContract < ApplicationService
      # Il result di ogni fase è validato contro il $def del contratto canonico VENDORIZZATO. L'assenza
      # di contract_version identifica lo storico v1; il valore 2 attiva il decision packet strutturato.
      # La barriera server è esattamente lo schema pubblicato, senza drift tra la consegna e il contratto. Gli
      # stati non-avanzanti (waiting/escalated/blocked) sono accettati dallo schema ma non processati dagli
      # effetti (nessun avanzamento di coda): restano fermi per l'intervento umano.
      CONTRACT_SCHEMAS = [ 1, 2 ].to_h do |version|
        [ version, JSON.parse(Rails.root.join("contracts/agent-result/v#{version}/schema.json").read).freeze ]
      end.freeze
      RESULT_DEFINITIONS = {
        "triage" => "triage_result", "planner" => "planner_result", "autopilot" => "autopilot_result",
        "closer_staging" => "closer_staging_result", "closer_production" => "closer_production_result"
      }.freeze
      # CYAU-173 — `regexp_resolver: "ecma"` non e un dettaglio: JSON Schema dichiara i `pattern` in
      # ECMA-262, dove `^` e `$` ancorano la STRINGA. Ruby li interpreta come ancore di RIGA, quindi col
      # resolver di default (`ruby`) un valore multi-riga passa se la PRIMA riga combacia: la stringa
      # "https://github.com/a/b/pull/1\nQUALSIASI-COSA" era accettata dal server e rifiutata dalla
      # macchina. E' esattamente la divergenza che quel ticket chiude — una parte accetta cio che
      # l'altra rifiuta, e il lavoro viene fatto per intero e poi buttato alla consegna.
      RESULT_VALIDATORS = CONTRACT_SCHEMAS.to_h do |version, schema|
        validators = RESULT_DEFINITIONS.values.to_h do |definition|
          [ definition, JSONSchemer.schema(
            { "$schema" => schema.fetch("$schema"), "$defs" => schema.fetch("$defs"),
              "$ref" => "#/$defs/#{definition}" }, regexp_resolver: "ecma"
          ) ]
        end.freeze
        [ version, validators ]
      end.freeze
      REVIEW_VALIDATOR_V2 = JSONSchemer.schema(
        { "$schema" => CONTRACT_SCHEMAS.fetch(2).fetch("$schema"),
          "$defs" => CONTRACT_SCHEMAS.fetch(2).fetch("$defs"), "$ref" => "#/$defs/review_envelope" },
        regexp_resolver: "ecma"
      )

      def initialize(attempt:, payload:)
        @attempt = attempt
        @payload = payload
      end

      # nil = la consegna passa; altrimenti il Result.err con cui va respinta.
      def call
        # CYAU-226: the engine named when the work was claimed; its own engine means a new session of it.
        expected_reviewer = @attempt.reviewer
        valid_review = @payload["runtime"] == @attempt.runtime &&
                       @payload["reviewer_runtime"] == expected_reviewer &&
                       @payload.dig("review", "status") == "accepted" &&
                       @payload.dig("review", "summary").is_a?(String) &&
                       @payload.dig("review", "summary").present? &&
                       valid_review_contract? &&
                       valid_review_depth? &&
                       valid_review_attestation?
        return review_failed unless valid_review
        return unreviewed_delivered_head unless delivered_head_reviewed?
        return missing_observed_head unless valid_observed_head?
        return invalid_result unless valid_result?
        return wrong_release unless valid_release?

        nil
      end

      # La review registrata porta la profondità che il SERVER ha preteso, non quella che l'host ha detto:
      # così l'audit di ogni consegna accettata dice quale rilettura era dovuta, anche quando arriva da un
      # host che non dichiara il campo. Sul ramo bocciato il payload resta invece tale e quale (vedi
      # Attempts::Deliver#call): è la prova di ciò che l'host ha dichiarato, e riscriverla col valore dovuto
      # cancellerebbe proprio il motivo del rifiuto.
      def reviewed_review = @payload.fetch("review").merge("depth" => effective_review_depth)

      private

      # CYRA-621 — il numero pubblicato dev'essere QUELLO assegnato dal server, e per la versione
      # definitiva anche il punto di codice.
      #
      # Prima il numero lo sceglieva la macchina pochi secondi prima di pubblicare, e nessuno
      # controllava quella scelta né prima né dopo: se sbagliava a valutare il tipo di cambiamento, il
      # numero raccontava una cosa falsa e non c'era modo di accorgersene. Ora se pubblica con un
      # numero diverso da quello assegnato, la consegna viene rifiutata e quel rilascio non diventa
      # mai «fatto».
      #
      # Vale solo sui rami che hanno DAVVERO rilasciato: uno stato che non pubblica niente non ha un
      # numero da confrontare, e pretenderlo lo boccerebbe per una prova che non poteva portare.
      RELEASED_STATES = %w[staging-released production-released].freeze

      def valid_release?
        return true unless Agents::ReleaseAssignment::PHASES.include?(@attempt.phase)
        return true unless @payload.dig("result", "state").in?(RELEASED_STATES)

        assignment = Agents::ReleaseAssignment.find_by(workflow_id: @attempt.workflow_id,
                                                      execution_phase: @attempt.phase)
        return false if assignment.nil?
        return false unless @payload.dig("result", "tag") == assignment.version

        assignment.sha.blank? || @payload.dig("result", "commit") == assignment.sha
      end

      def wrong_release
        Result.err(AppError.new("Il rilascio non porta il numero di versione assegnato",
                                code: "R409-ATTEMPT-005", status: :conflict))
      end

      # CYAU-178 — le fasi che SCRIVONO codice devono dire quale codice avevano davvero in mano.
      #
      # Oggi la consegna allega un indirizzo di proposta e il sistema si fida dell'indirizzo. Un
      # indirizzo che punta al lavoro di un altro ticket, a una versione vecchia, o a un lavoro il cui
      # ultimo invio non è mai partito, da fuori sono identici: tutti e tre passano, e chi approva
      # guarda una pagina verde che mostra un lavoro a metà.
      #
      # Qui NON si confronta con GitHub: questa validazione gira sotto lock (Attempts::Deliver#lock_scope!)
      # e una chiamata HTTP là dentro terrebbe righe bloccate per la durata di una rete che non risponde.
      # Qui si pretende soltanto che il dato ci sia e abbia la forma giusta; il confronto con lo stato vivo
      # della proposta lo fa chi quella proposta la legge.
      #
      # Le fasi che non scrivono codice non lo portano, e pretenderlo da loro sarebbe una domanda senza
      # risposta possibile — lo stesso inciampo del planner a cui si chiedevano le prove eseguite.
      def valid_observed_head?
        return true unless Agents::PhaseProfile.for(@attempt.phase)&.write_access?

        @payload.dig("observed", "head_sha").to_s.match?(/\A[0-9a-f]{40}\z/)
      end

      def missing_observed_head
        Result.err(AppError.new("Consegna senza l'impronta del codice prodotto",
                                code: "R409-ATTEMPT-004", status: :conflict))
      end

      # PROFONDITÀ della rilettura incrociata (CYRA-285): la decide la FASE, mai l'host. Il triage produce
      # cinque campi e si rilegge su quelli; l'autopilot e i due closer toccano il repository e restano
      # riletti sul diff. Il gate è qui, server-side, perché un host che potesse scegliersi la profondità
      # farebbe sparire la garanzia esattamente dove serve: un autopilot dichiarato riletto "sul solo
      # result" è un diff che nessuno ha guardato.
      #
      # CYAU-176 — una review che NON dichiara la profondità NON passa più. Fino a ieri passava, e passava
      # in silenzio: un rapporto che non dice come è stato riletto è un rapporto a cui manca esattamente la
      # parte che si sta validando, e accettarlo rendeva il campo un'etichetta facoltativa — cioè inutile.
      # Il valore resta comunque quello del SERVER sulla review registrata (vedi #reviewed_review): il
      # payload non fissa niente, deve solo dire la stessa cosa. Una dichiarazione DISCORDE è rifiutata in
      # entrambi i versi, anche "diff" su una fase che non ha un diff: dichiarare una rilettura che per
      # quella fase non esiste è un rapporto che non torna. Fase sconosciuta → nessuna profondità dovuta →
      # qualunque dichiarazione è discorde (fail-closed).
      def valid_review_depth?
        @payload.dig("review", "depth").in?(accepted_review_depths)
      end

      # CYRA-757 — gli stati che NON producono un diff si rileggono sul solo result, come già fa l'host
      # (CYAU-187): `already-delivered` (il lavoro sta in una proposta aperta prima, non nella copia di
      # lavoro) e `blocked` (l'agente si è fermato senza toccare niente). Pretendere «diff» più le
      # impronte dove un diff non esiste bocciava una consegna onesta con «revisione non approvata», e
      # la lavorazione si fermava dopo due giri senza che nessuno capisse perché. La rilettura sul diff
      # resta ammessa anche qui: è più stretta, non meno.
      STATES_WITHOUT_DIFF = %w[blocked already-delivered].freeze

      def accepted_review_depths
        required = review_depth
        return [ required ].compact unless required == Agents::PhaseProfile::REVIEW_DEPTH_DIFF
        return [ required ] unless result_state.in?(STATES_WITHOUT_DIFF)

        [ Agents::PhaseProfile::REVIEW_DEPTH_RESULT, required ]
      end

      # Un `result` che non è un oggetto lo boccia `valid_result?`: qui non deve esplodere prima.
      def result_state
        result = @payload["result"]
        result["state"] if result.is_a?(Hash)
      end

      # La profondità che finisce nell'audit: quella dichiarata, se è fra le ammesse per la fase e lo
      # stato; altrimenti quella dovuta dal profilo (il ramo bocciato non passa di qui).
      def effective_review_depth
        declared = @payload.dig("review", "depth")
        declared.in?(accepted_review_depths) ? declared : review_depth
      end

      # CYAU-176 — con profondità "diff" le tre impronte di ciò che il reviewer ha REALMENTE letto sono
      # obbligatorie. Sono la differenza fra "ho riletto il codice" affermato e dimostrato: senza, il campo
      # `depth` tornerebbe a essere una parola che l'host può scrivere a costo zero.
      #
      # Il server NON le confronta con un diff proprio: non ha il worktree e non può ricalcolarle. Servono a
      # rendere la dichiarazione verificabile a posteriori e a impedire che sia scrivibile a vuoto; il
      # confronto con lo snapshot letto lo fa l'host, che è l'unico che il diff ce l'ha davanti.
      #
      # Le lunghezze NON sono uguali e non vanno uniformate: le prime due sono oggetti Git (SHA-1, 40) e la
      # terza è l'impronta del diff (SHA-256, 64). Pretendere 40 su tutte e tre rifiuterebbe ogni consegna
      # onesta; pretendere "esadecimale e basta" lascerebbe passare un troncamento.
      REVIEWED_FINGERPRINTS = {
        "reviewed_base_commit" => /\A[0-9a-f]{40}\z/,
        "reviewed_snapshot_tree" => /\A[0-9a-f]{40}\z/,
        "reviewed_diff_sha256" => /\A[0-9a-f]{64}\z/
      }.freeze

      def valid_review_attestation?
        return true unless effective_review_depth == Agents::PhaseProfile::REVIEW_DEPTH_DIFF

        REVIEWED_FINGERPRINTS.all? { |field, shape| @payload.dig("review", field).to_s.match?(shape) }
      end

      def review_depth = Agents::PhaseProfile.for(@attempt.phase)&.review_depth

      def valid_result?
        result = @payload["result"]
        return false unless result.is_a?(Hash)
        # Anti cross-ticket: il codice del result deve essere quello del ticket del tentativo (un result generato
        # per un altro ticket, consegnato all'URL di questo attempt, non deve avanzarlo).
        return false unless result["code"] == @attempt.workflow.ticket.code
        return false unless contract_valid?(result)

        # Oltre allo schema: le domande di chiarimento superano le regole del modello Clarification (no comandi/URL).
        return valid_clarification_questions?(result) if triage_clarification?(result)

        delivery_within_frozen_scope?(result)
      end

      # CYRA-612 — la proposta consegnata deve stare in uno dei progetti che sono stati FISSATI quando
      # una persona ha approvato il piano (CYRA-610). Se sta altrove la consegna è respinta e ne resta
      # traccia; se la cosa si ripete, la lavorazione si ferma e chiama una persona
      # (Attempts::Deliver#settle_rejected_phase!).
      #
      # Attenzione a cosa questo NON fa: qui si legge soltanto l'INDIRIZZO scritto nel rapporto, non si
      # apre niente. Un indirizzo inventato ma scritto bene supera questo passo; a smascherarlo è il
      # controllo dopo, quello che la proposta la apre davvero.
      #
      # Vale solo per l'autopilot che avanza: le altre fasi non consegnano una proposta.
      def delivery_within_frozen_scope?(result)
        return true unless @attempt.phase == "autopilot"
        return true unless result["state"].in?(Effects::Autopilot::ADVANCING_STATES)

        coordinate = PullRequestUrl.coordinates(result.dig("delivery", "prUrl"))
        return false unless coordinate

        # Vincolo assente = respinta. Le lavorazioni il cui piano è stato approvato prima che l'elenco
        # esistesse non hanno niente con cui confrontarsi: si chiedono modifiche al piano e lo si
        # approva di nuovo. Accettarle «perché il dato manca» rimetterebbe in piedi proprio il buco.
        allowed = Array(@attempt.workflow.frozen_plan&.candidate_items)
                  .filter_map { |item| item["repo"].to_s.downcase.presence if item.is_a?(Hash) }
        allowed.include?(coordinate[:full_name].downcase)
      end

      # Parità col contratto vendorizzato: il result valida contro il $def della propria fase.
      def contract_valid?(result)
        definition = RESULT_DEFINITIONS[@attempt.phase] or return false
        version = result_contract_version(result) or return false
        RESULT_VALIDATORS.fetch(version).fetch(definition).valid?(result)
      end

      def result_contract_version(result)
        return 1 unless result.key?("contract_version")
        return 2 if result["contract_version"] == 2

        nil
      end

      def valid_review_contract?
        result = @payload["result"]
        return true unless result.is_a?(Hash) && result["contract_version"] == 2

        REVIEW_VALIDATOR_V2.valid?(@payload["review"])
      end

      def triage_clarification?(result)
        @attempt.phase == "triage" && result["state"] == "needs-clarification"
      end

      # CYRA-784 — `asked` e non più il jsonb: la regola del giro (quante domande, e che forma hanno)
      # è rimasta dov'era, sull'attributo che il chiamante sta per scrivere. Le domande, invece, ora
      # nascono solo come righe di primo livello.
      def valid_clarification_questions?(result)
        Agents::Clarification.new(
          workflow: @attempt.workflow, attempt: @attempt, asked: Agents::Clarifications::Ask.texts(result["questions"])
        ).valid?
      end

      def review_failed
        Result.err(AppError.new("Revisione incrociata mancante o non approvata",
                                code: "R409-ATTEMPT-003", status: :conflict))
      end

      # CYRA-1004 — already-delivered work reviewed on the result alone passes only if an earlier attempt
      # of this workflow had THIS head accepted by a diff review. Otherwise a pushed diff whose review was
      # unavailable came back on retry as "already delivered" and moved on without anyone reading it.
      def delivered_head_reviewed?
        return true unless result_state == "already-delivered"
        return true unless @payload.dig("review", "depth") == Agents::PhaseProfile::REVIEW_DEPTH_RESULT

        head = @payload.dig("observed", "head_sha").presence or return false
        @attempt.workflow.attempts.where(phase: @attempt.phase, review_status: :accepted, observed_head_sha: head)
                .where.not(id: @attempt.id)
                .any? { |earlier| earlier.review.is_a?(Hash) && earlier.review["depth"] == Agents::PhaseProfile::REVIEW_DEPTH_DIFF }
      end

      def unreviewed_delivered_head
        Result.err(AppError.new("Codice già consegnato ma mai riletto sul diff",
                                code: "R409-ATTEMPT-006", status: :conflict))
      end

      def invalid_result
        Result.err(AppError.new("Risultato strutturato non valido",
                                code: "R422-ATTEMPT-001", status: :unprocessable_content))
      end
    end
  end
end
