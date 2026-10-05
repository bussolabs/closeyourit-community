# frozen_string_literal: true

module Agents
  class Workflow < ApplicationRecord
    belongs_to :ticket, class_name: "Ticketing::Ticket", inverse_of: :agent_workflow
    # Host-first (CYAU-83, expand-only): CHI (host + service account) ha eseguito ogni fase, denormalizzato
    # accanto ai *_by_agent (che restano). Pointer di comodo per l'audit; la scrittura è nel claim (CYAU-82).
    belongs_to :triage_by_host, class_name: "Agents::Host", optional: true
    belongs_to :triage_by_service_account, class_name: "Accounts::Account", optional: true
    belongs_to :planned_by_host, class_name: "Agents::Host", optional: true
    belongs_to :planned_by_service_account, class_name: "Accounts::Account", optional: true
    belongs_to :autopilot_by_host, class_name: "Agents::Host", optional: true
    belongs_to :autopilot_by_service_account, class_name: "Accounts::Account", optional: true
    belongs_to :closer_staging_by_host, class_name: "Agents::Host", optional: true
    belongs_to :closer_staging_by_service_account, class_name: "Accounts::Account", optional: true
    belongs_to :closer_production_by_host, class_name: "Agents::Host", optional: true
    belongs_to :closer_production_by_service_account, class_name: "Accounts::Account", optional: true
    belongs_to :approved_by, class_name: "Accounts::Account", optional: true
    belongs_to :autopilot_approved_by, class_name: "Accounts::Account", optional: true
    # Chi ha autorizzato il rilascio in produzione (CYRA-504): gemella di autopilot_approved_by, ed è
    # l'unica prova di CHI ha dato il via libera all'unico passo irreversibile della catena.
    belongs_to :closer_production_approved_by, class_name: "Accounts::Account", optional: true
    belongs_to :cancelled_by, class_name: "Accounts::Account", optional: true
    # CYRA-601 — il piano su cui l'operatore ha premuto approva, congelato: da lì in avanti le due
    # decisioni che porta dentro non si riscrivono più. Puntare al piano di un'ALTRA lavorazione
    # significherebbe eseguire un lavoro approvato per un altro ticket.
    belongs_to :frozen_plan, class_name: "Agents::Plan", optional: true
    has_many :attempts, class_name: "Agents::Attempt", foreign_key: :workflow_id,
                        inverse_of: :workflow, dependent: :destroy
    has_many :clarifications, class_name: "Agents::Clarification", foreign_key: :workflow_id,
                              inverse_of: :workflow, dependent: :destroy
    has_many :plans, -> { order(:version) }, class_name: "Agents::Plan", foreign_key: :workflow_id,
                                              inverse_of: :workflow, dependent: :destroy

    has_many :delivery_candidates, class_name: "Agents::DeliveryCandidate", foreign_key: :workflow_id,
                                   inverse_of: :workflow, dependent: :destroy
    belongs_to :review_candidate, class_name: "Agents::DeliveryCandidate", optional: true
    # CYRA-624 — le prove del rilascio. Ne resta viva una sola per volta (indice parziale): due
    # sarebbero due verità sullo stesso rilascio.
    has_many :probes, class_name: "Agents::WorkflowProbe", foreign_key: :workflow_id,
                      inverse_of: :workflow, dependent: :destroy

    validates :ticket_id, uniqueness: true
    validate :frozen_plan_belongs_here
    validate :review_candidate_belongs_here

    before_update :ensure_review_candidate_is_write_once

    # L'ordine di demolizione e' scritto per esteso e non affidato alla posizione delle has_many qui
    # sopra, che chiunque puo rimescolare senza sapere cosa rompe: le foreign key dei figli verso
    # `agents_attempts` sono a on_delete: :restrict di PROPOSITO. `prepend: true` lo fa girare prima
    # dei callback che `dependent: :destroy` installa da solo. CYRA-664
    before_destroy :destroy_children_in_database_order, prepend: true

    delegate :project, to: :ticket

    def organization = ticket.project.organization

    # Il puntatore alla verifica si può SPOSTARE, ma solo passando dal vuoto: saltare da una riga
    # all'altra senza azzerare in mezzo sposterebbe di nascosto una decisione su un'altra prova. La
    # prova vera è la RIGA del registro, immutabile dal verdetto in poi, non questo puntatore. Nessun
    # vincolo di database può dirlo — è una relazione fra due righe. CYRA-604, CYRA-617
    def ensure_review_candidate_is_write_once
      return if review_candidate_id_was.nil? || review_candidate_id.nil?
      return if review_candidate_id_was == review_candidate_id

      raise ActiveRecord::ReadOnlyRecord,
            "La lavorazione sta già guardando una riga: per puntarne un'altra si azzera prima questa"
    end

    # Gemello di frozen_plan_belongs_here: la chiave esterna copre «riga inesistente», questo copre
    # «riga di un'altra lavorazione», che nessun vincolo di database sa vedere.
    def review_candidate_belongs_here
      return if review_candidate_id.blank?
      return if review_candidate&.workflow_id == id

      errors.add(:review_candidate_id, "non è una verifica di questa lavorazione")
    end

    def frozen_plan_belongs_here
      return if frozen_plan_id.blank?
      return if frozen_plan&.workflow_id == id

      errors.add(:frozen_plan_id, "non è un piano di questa lavorazione")
    end

    # Gemello SQL di #ready_execution_phase (stessi predicati + guardia terminale), table-qualified così da
    # funzionare joinato e nella subquery deferral correlata di Next (CYAU-79). Costante fidata (nessun input
    # utente) → interpolabile in sicurezza; la parità col metodo Ruby è verificata da spec. Ad aprire la
    # strada alla produzione è la PROVA (`closer_staging_verified_at`), non un terzo permesso. CYRA-629, CYRA-620
    READY_EXECUTION_PHASE_SQL = <<~SQL.squish.freeze
      CASE
        WHEN agents_workflows.cancelled_at IS NOT NULL OR agents_workflows.completed_at IS NOT NULL
          OR agents_workflows.blocked_at IS NOT NULL THEN NULL
        WHEN agents_workflows.triage_requested_at IS NOT NULL
          AND agents_workflows.triage_started_at IS NULL
          AND agents_workflows.triaged_at IS NULL THEN 'triage'
        WHEN agents_workflows.triaged_at IS NOT NULL
          AND agents_workflows.planned_at IS NULL THEN 'planner'
        WHEN agents_workflows.approved_at IS NOT NULL
          AND agents_workflows.autopilot_started_at IS NULL THEN 'autopilot'
        WHEN agents_workflows.autopilot_approved_at IS NOT NULL
          AND agents_workflows.closer_staging_started_at IS NULL THEN 'closer_staging'
        WHEN agents_workflows.closer_staging_verified_at IS NOT NULL
          AND agents_workflows.closer_production_started_at IS NULL
          AND agents_workflows.closer_production_completed_at IS NULL THEN 'closer_production'
      END
    SQL

    # Fase eseguibile → (colonna di avvio, marcatore che ne segna la conclusione). Serve al recovery di una
    # fase interrotta (CYRA-212). Il planner NON è qui: non ha un avvio dedicato (la sua prontezza è
    # triaged_at→planned_at), quindi torna proposto da solo alla scadenza del lease. closer_production si
    # conclude col SUO marcatore: finire la fase non vuol dire che il rilascio è in piedi. CYRA-624
    PHASE_START_COLUMNS = {
      "triage" => { started: :triage_started_at, done: :triaged_at },
      "autopilot" => { started: :autopilot_started_at, done: :autopilot_completed_at },
      "closer_staging" => { started: :closer_staging_started_at, done: :closer_staging_completed_at },
      "closer_production" => { started: :closer_production_started_at, done: :closer_production_completed_at }
    }.freeze

    # Marcatore che segna la CONCLUSIONE di ogni fase eseguibile (CYRA-280). PHASE_START_COLUMNS non basta:
    # il planner non ha un avvio dedicato e per questo non compare lì, ma si conclude eccome — il piano
    # prodotto è planned_at. Serve a distinguere una bocciatura ancora aperta da una superata: gli attempt
    # sono audit immutabile e restano in archivio anche quando la fase è stata rifatta e chiusa.
    PHASE_DONE_COLUMNS = {
      "triage" => :triaged_at,
      "planner" => :planned_at,
      "autopilot" => :autopilot_completed_at,
      "closer_staging" => :closer_staging_completed_at,
      "closer_production" => :closer_production_completed_at
    }.freeze

    # execution_phase reclamabile ORA per questo ticket, o nil: sorgente unica host-first di "quale fase è
    # pronta". NON sono gli stati FSM di #phase — un planner bocciato in review resta reclamabile finché il
    # retry ha budget, mentre #phase dà review_blocked. blocked_at sta accanto a cancelled/completed e non
    # fra le condizioni di fase: chi ha chiamato una persona resta fermo su TUTTE le fasi. CYRA-218
    def ready_execution_phase
      return if cancelled_at? || completed_at? || blocked_at?
      return "triage" if triage_requested_at? && triage_started_at.nil? && triaged_at.nil?
      return "planner" if triaged_at? && planned_at.nil?
      return "autopilot" if approved_at? && autopilot_started_at.nil?
      return "closer_staging" if autopilot_approved_at? && closer_staging_started_at.nil?
      # Ad aprire la produzione è la PROVA, non la dichiarazione del closer; `closer_staging_completed_at`
      # resta il marcatore di consegna, o chi riapre le fasi morte ne farebbe un secondo merge e un
      # secondo tag. `closer_production_completed_at` chiude la fase anche se il recupero ne riazzera
      # l'avvio: reclamabile qui vuol dire un SECONDO rilascio dello stesso lavoro. CYRA-620, CYRA-624
      if closer_staging_verified_at? &&
         closer_production_started_at.nil? && closer_production_completed_at.nil?
        return "closer_production"
      end

      nil
    end

    # La macchina che ha toccato per ultima la lavorazione, dalla fase più avanzata alla prima. È
    # l'UNICA catena di ricaduta: coda delle approvazioni ed elenco delle lavorazioni in volo devono dire
    # lo stesso nome per lo stesso workflow. Nil resta nil — nessuna macchina registrata è
    # un'informazione, non un buco da riempire. CYRA-689
    def attributed_host_id
      closer_production_by_host_id || closer_staging_by_host_id ||
        autopilot_by_host_id || planned_by_host_id || triage_by_host_id
    end

    # Riapre una fase avviata dal claim ma mai conclusa perché l'host è morto a metà: azzera
    # <fase>_started_at e l'attribuzione host-first, così la fase torna proposta — chiudere il solo attempt
    # come `stale` non basta, lo start resta scritto qui. UPDATE condizionale atomico: mai su una fase già
    # conclusa, mai avviata o su un workflow terminale. Ritorna true se ha riaperto qualcosa. CYRA-212
    def reopen_execution_phase!(phase)
      columns = PHASE_START_COLUMNS[phase.to_s]
      return false unless columns

      affected = self.class
                     .where(id: id, cancelled_at: nil, completed_at: nil, columns[:done] => nil)
                     .where.not(columns[:started] => nil)
                     .update_all(
                       columns[:started] => nil,
                       "#{phase}_by_host_id" => nil,
                       "#{phase}_by_service_account_id" => nil,
                       updated_at: Time.current
                     )
      affected.positive?
    end

    # Rimanda al lavoro una fase CONCLUSA che una persona ha rifiutato: gemello di
    # #reopen_execution_phase!, e serve dove quello si rifiuta di agire — lì il marcatore di conclusione
    # è vuoto, qui c'è, e il rifiuto dice che va rifatta, quindi lo azzera. Stesso UPDATE condizionale
    # atomico del gemello. Ritorna true se ha rimandato indietro qualcosa.
    def send_phase_back_to_work!(phase)
      columns = PHASE_START_COLUMNS[phase.to_s]
      return false unless columns

      affected = self.class
                     .where(id: id, cancelled_at: nil, completed_at: nil)
                     .where.not(columns[:started] => nil)
                     .update_all(
                       columns[:started] => nil,
                       columns[:done] => nil,
                       "#{phase}_by_host_id" => nil,
                       "#{phase}_by_service_account_id" => nil,
                       updated_at: Time.current
                     )
      affected.positive?
    end

    # La fase di ESECUZIONE su cui la lavorazione si è fermata, o nil. Le due sorgenti non sono
    # intercambiabili: se a fermare è stata la macchina vale la fase SCRITTA NEL BLOCCO (un blocco
    # dichiarato dall'agente non produce attempt bocciati), sui blocchi da tetto dei tentativi vale
    # quella dedotta dagli attempt. Scritta una volta sola: la leggono Unblock e #reassessable?.
    def stopped_execution_phase
      return blocked_phase.presence if blocked_kind == "agent_blocked"

      stalled_review_phase
    end

    # «Serve ancora, o è già fatto?» si può chiedere finché il lavoro è dalle parti della pianificazione;
    # dall'autopilot in poi il codice l'ha scritto la macchina e la domanda giusta è «va bene?», che ha
    # già i suoi pulsanti. Il gate vive QUI e non nella pagina — Workflows::Reassess lo rilegge sotto
    # lock, così nessuna strada può offrire una decisione che il dominio poi rifiuta. CYRA-675
    def reassessable?
      return false if cancelled_at? || completed_at?

      case Agents::Workflows::PhaseResolver.stage(phase)
      when "to_plan", "plan_to_approve" then true
      when "blocked"
        # Qui la domanda è DOVE si è fermata, non cosa riaprire, e non si risponde con
        # #stopped_execution_phase: quello torna nil sul planner, che è il caso più comune — una
        # pianificazione bocciata fino al tetto — e il pulsante sparirebbe dove serve.
        stop_point = blocked_phase.presence || stalled_review_phase
        Agents::Workflows::PhaseResolver.step_of_execution_phase(stop_point) == "to_plan"
      else false
      end
    end

    # La fase che una bocciatura in review ha lasciato FERMA, o nil: un attempt bocciato è terminale e
    # non muove nessun timestamp, quindi lo start resta scritto e la fase smette di essere proposta.
    # Vince la PIÙ AVANZATA fra le bocciate; un tentativo ancora aperto sulla stessa fase la tiene
    # FUORI — lì non è ferma, sta riprovando, e riaprirla metterebbe un secondo host sul lavoro. CYRA-267
    def stalled_review_phase
      return if cancelled_at? || completed_at?

      failed = attempts.status_review_failed.distinct.pluck(:phase)
      return if failed.empty?

      stalled_review_phase_from(failed, attempts.where.not(status: Agents::Attempt::TERMINAL_STATUSES)
                                                .distinct.pluck(:phase))
    end

    # Gemello PURO di #stalled_review_phase: stessa regola, ma le due `pluck` arrivano da fuori già
    # caricate in blocco. Serve alla coda delle approvazioni — chiederlo al gemello impuro sarebbe due
    # query per workflow, cioè un N+1 in coda. La regola sta scritta UNA volta e la parità fra i due è
    # verificata da spec. CYRA-317
    def stalled_review_phase_from(failed_phases, open_phases)
      return if cancelled_at? || completed_at?
      return if failed_phases.blank?

      open = open_phases.to_a
      PHASE_START_COLUMNS.keys.reverse.find do |phase|
        columns = PHASE_START_COLUMNS.fetch(phase)
        failed_phases.include?(phase) && open.exclude?(phase) &&
          self[columns[:started]].present? && self[columns[:done]].blank?
      end
    end

    # Attributi che tolgono il blocco da tetto di revisione: stanno insieme perché vanno scritti
    # insieme — chi sblocca senza far ripartire il budget concede un tentativo invece dei due
    # dichiarati, visto che gli attempt bocciati restano a contare per sempre. I tre punti che
    # sbloccano li fondono nel proprio UPDATE per restare atomici. CYRA-218
    def self.cleared_block(now = Time.current)
      # `blocked_kind` e `unreachable_count` si azzerano insieme al resto (CYRA-598): lasciare
      # l'autore di un blocco tolto farebbe leggere alla prossima frase un motivo che non esiste
      # più, e lasciare il conteggio farebbe bloccare al primo «non riesco a guardare» dopo lo
      # sblocco — un giro concesso che non è un giro.
      { blocked_at: nil, blocked_phase: nil, blocked_reason: nil, blocked_kind: nil,
        unreachable_count: 0, review_budget_from: now }
    end

    # CYRA-871 — chi ha fermato il rilascio prima della produzione, scritto nel motivo del blocco.
    def held_by_name
      blocked_reason.to_s.delete_prefix("#{Agents::Workflows::HoldProduction::KIND}: ").presence if
        blocked_kind == Agents::Workflows::HoldProduction::KIND
    end

    # Il motivo dell'agente ripulito dal prefisso tecnico, pronto da mostrare. Sta QUI e non nel
    # presenter perché lo leggono in due (riga di sintesi e banner della scheda) e due copie
    # divergono. Il prefisso (`agent_blocked:`, `unreachable: …`) è audit, non una frase da leggere:
    # serve a rendere le righe confrontabili fra loro e nel tempo.
    def agent_block_reason
      blocked_reason.to_s
                    .sub(/\A(agent_blocked|unreachable):[^—]*—\s*/, "")
                    .sub(/\Aagent_blocked:\s*/, "")
                    .strip
                    .presence
    end

    # La fase la calcola Agents::Workflows::PhaseResolver, per tutti: la catena sta scritta una volta
    # sola, o la stessa lavorazione si racconta in un modo nella scheda e in un altro nella coda. Qui
    # resta solo ciò che il risolutore non può sapere da sé — quali fasi hanno una bocciatura in
    # revisione — perché lui è PURO e le riceve precaricate. CYRA-796
    def phase
      Agents::Workflows::PhaseResolver.phase(self, failed_review_phases.to_set)
    end

    # Quante volte la fase su cui si è fermata è andata a vuoto: è IL numero che ha fatto scattare la
    # fermata, quindi conta gli stessi stati del tetto (anche i giri morti) e solo dall'ultimo sblocco
    # in poi — gli attempt sono archivio immutabile e contarli tutti direbbe più del tetto. `attempts`
    # può arrivare già caricato da chi lo ha in mano per altro. CYRA-618
    def stopped_failures(attempts = nil)
      from = review_budget_from
      list = attempts || self.attempts.to_a
      list.count do |attempt|
        attempt.phase == blocked_phase &&
          Agents::Workflows::BlockExhaustedPhase::COUNTED_STATUSES.include?(attempt.status) &&
          (from.nil? || attempt.created_at >= from)
      end
    end

    # «Finita, in un modo o nell'altro»: conclusa o annullata, scritta qui e non nei tre punti che se
    # la chiedevano. NON è il contrario di `work_in_progress?` — una lavorazione mai avviata non è né
    # in corso né finita, ed è la differenza che tiene aperta la strada di chi lavora a mano. CYRA-613
    def terminal? = cancelled_at? || completed_at?

    # «DAVVERO in corso»: avviata da una macchina, non finita e non abbandonata. È il predicato che
    # decide chi puo' spostare lo stato del ticket. NON e' «workflow non terminale» (ogni ticket nasce
    # con una lavorazione, li bloccherebbe quasi tutti) e non e' «avviata e mai conclusa», che non
    # scade mai e terrebbe fermo per sempre un ticket lasciato a meta'. CYRA-609, CYRA-673
    def work_in_progress?
      return false unless triage_started_at?
      return false if completed_at? || cancelled_at?

      someone_working?
    end

    # Il lease e' l'autorita' sulla mutua esclusione e porta gia' la propria scadenza; un tentativo
    # fuori dagli stati terminali e' lavoro davvero in volo. Senza nessuno dei due, il ticket e'
    # libero: e' quello che il lease stesso sta dicendo quando e' assente o scaduto.
    def someone_working?
      return true if ticket.agent_lease&.active_at?(Time.current)
      return true if attempts.where.not(status: Agents::Attempt::TERMINAL_STATUSES).exists?

      # Nessun titolare e nessun tentativo in volo NON significa ancora abbandono: fra una fase e
      # l'altra il lease e' rilasciato e i tentativi sono tutti conclusi, e in quella finestra la
      # lavorazione e' viva. Quello che separa la pausa dall'abbandono e' quanto tempo e' passato.
      last_sign_of_life > Agents::Constants::WORKFLOW_ABANDONED_AFTER.ago
    end

    # Solo i segni che riguardano il LAVORO: l'ultimo tentativo, o l'avvio se tentativi non ce ne
    # sono ancora. `updated_at` del workflow no — cambia per motivi che col lavoro non c'entrano
    # (una revisione, un campo di servizio) e terrebbe vivo un abbandono a ogni sfioramento.
    def last_sign_of_life
      [ attempts.maximum(:updated_at), triage_started_at ].compact.max
    end

    # Stessa domanda, altro uso: quando il lavoro è in corso il CORPO del ticket non si tocca più,
    # perché la macchina sta implementando proprio quel testo. Alias e non una seconda definizione: due
    # copie della stessa condizione divergono il giorno in cui una impara qualcosa e l'altra no.
    alias_method :body_locked?, :work_in_progress?

    # Almeno una delle fasi bocciate è ancora APERTA, cioè nessun tentativo successivo l'ha conclusa.
    # Predicato PURO (prende le fasi già plucked) perché lo chiama la catena, pura a sua volta; sta qui
    # e non lì perché legge PHASE_DONE_COLUMNS, vocabolario di questo modello. Fase fuori vocabolario
    # → conta come aperta, fail-closed. CYRA-280
    def open_review_failure?(failed_phases)
      failed_phases.any? do |phase|
        column = PHASE_DONE_COLUMNS[phase]
        column.nil? || self[column].blank?
      end
    end

    private

    # Il workflow punta a due dei propri figli (`frozen_plan_id`, `review_candidate_id`) con
    # foreign key senza on_delete: finche quei riferimenti esistono, distruggere il piano o il
    # candidato li violerebbe. Vanno sciolti per primi, poi i figli degli attempt, poi gli attempt.
    def destroy_children_in_database_order
      update_columns(frozen_plan_id: nil, review_candidate_id: nil)

      delivery_candidates.destroy_all
      plans.destroy_all
      clarifications.destroy_all
      probes.destroy_all
      attempts.destroy_all
    end

    # Le phase con almeno una bocciatura, in UNA query. È l'unico ingrediente che #phase deve
    # procurarsi prima di chiedere la fase al risolutore: la catena le legge due volte (gate closer e
    # gate generale) e chiederle due volte sarebbe due query per una scheda sola.
    def failed_review_phases
      attempts.status_review_failed.distinct.pluck(:phase)
    end
  end
end
