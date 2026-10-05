# frozen_string_literal: true

module Agents
  module Workflows
    # LA catena delle fasi, l'unica: in che momento è una lavorazione, dai suoi timestamp. PURA
    # apposta — le fasi con una bocciatura in revisione arrivano da fuori già caricate, così una
    # lista le precarica in blocco (`failed_phases_by_workflow`) e la scheda le chiede per il suo
    # workflow. Ricopiarla la farebbe divergere al primo stato nuovo, e in silenzio. CYRA-796
    module PhaseResolver
      # Le fasi che aspettano una DECISIONE UMANA; il resto è lavoro in corso dell'agente.
      # Vocabolario unico: chi lo consuma lo riferisce, non lo ricopia. L'ordine conta —
      # Home::Approvals::Queue::STATES ne deriva ed è l'ordine dei chip dei filtri. Le fermate sono
      # due: il terzo permesso non decideva niente di nuovo e non poteva dire di no. CYRA-629
      HUMAN_GATED_PHASES = %w[awaiting_approval awaiting_autopilot_approval review_blocked].freeze

      # TUTTI i valori che la catena può restituire, accanto alla catena che li produce: un elenco
      # lontano diverge e la pagina finisce per stampare una parola inglese. Uno spec lo confronta
      # col SORGENTE qui sotto, quindi una fase nuova senza voce qui è suite rossa. CYRA-602
      PHASES = %w[
        inactive triage_queued triaging planning awaiting_approval autopilot_queued autopilot
        verifying_candidate awaiting_autopilot_approval closer_staging_queued closer_staging
        verifying_staging closer_production_queued closer_production
        awaiting_production_proof review_blocked completed cancelled
      ].freeze

      # Fase interna → la parola che leggi. Sedici momenti, otto parole: il dettaglio non sparisce,
      # resta nella frase sotto il nome.
      STAGE = {
        "inactive" => "to_plan",
        "triage_queued" => "to_plan", "triaging" => "to_plan", "planning" => "to_plan",
        "awaiting_approval" => "plan_to_approve",
        "autopilot_queued" => "in_progress", "autopilot" => "in_progress",
        # CYRA-615 — il controllo della proposta e' ancora lavoro in corso: non chiede niente, e
        # metterlo in `to_review` lo farebbe leggere come «tocca a te» proprio mentre non tocca a te.
        "verifying_candidate" => "in_progress",
        "awaiting_autopilot_approval" => "to_review",
        "closer_staging_queued" => "closing", "closer_staging" => "closing",
        # CYRA-620 — il controllo della prova è ancora chiusura: non chiede niente, e metterlo altrove
        # lo farebbe leggere come una tappa nuova che non esiste nel modello.
        "verifying_staging" => "closing",
        "closer_production_queued" => "closing", "closer_production" => "closing",
        # CYRA-624 — anche guardare se il rilascio è in piedi è chiusura: non chiede niente, e
        # metterlo su «fatto» direbbe che è finito proprio mentre si sta controllando se lo è.
        "awaiting_production_proof" => "closing",
        "review_blocked" => "blocked",
        "completed" => "done",
        "cancelled" => "cancelled"
      }.freeze

      # Le otto parole, in ordine di percorso. Le due uscite in coda: non sono tappe, sono uscite.
      STAGES = %w[to_plan plan_to_approve in_progress to_review closing done blocked cancelled].freeze

      # CYRA-619 — i SEI passaggi del modello, in ordine. Sono le tappe: le due uscite (fermata,
      # annullata) restano fuori perché non sono posti in cui il lavoro passa, sono modi di uscirne.
      # È questo l'elenco che disegna le colonne della plancia e la striscia della scheda: sono le
      # stesse sei parole con cui il ticket dice dove si trova, quindi non resta niente da tradurre.
      STEPS = STAGES.first(6).freeze

      # CYRA-631 — le due USCITE: non sono tappe, sono modi di uscire dal percorso. Si derivano per
      # differenza invece di riscriverle, così una parola nuova in STAGES finisce da sé o fra le tappe
      # o fra le uscite, e non può restare fuori da tutte e due.
      EXITS = (STAGES - STEPS).freeze

      # I passaggi che si fermano ad ASPETTARE UNA PERSONA, derivati da HUMAN_GATED_PHASES e non
      # scritti a mano: le guide li leggono da qui, quindi un permesso che nasce o che muore si
      # riflette da solo su quello che raccontano. `review_blocked` esce dal conto: la sua parola è
      # «bloccato», che è un'uscita e non una tappa. CYRA-629
      def self.waiting_steps = HUMAN_GATED_PHASES.map { |phase| stage(phase) }.uniq & STEPS

      # Dove collocare una fermata: la fase di ESECUZIONE che il dominio scrive in `blocked_phase` non
      # è uno stato della catena, quindi `STAGE` non la conosce. Serve solo a mettere il segno rosso
      # sul passaggio giusto.
      STEP_OF_EXECUTION_PHASE = {
        "triage" => "to_plan", "planner" => "to_plan",
        "autopilot" => "in_progress",
        "closer_staging" => "closing", "closer_production" => "closing"
      }.freeze

      # Il passaggio di una fase di esecuzione. Nil quando non la conosciamo: meglio nessun segno che
      # un segno sul passaggio sbagliato.
      def self.step_of_execution_phase(phase) = STEP_OF_EXECUTION_PHASE[phase.to_s]

      # Il passaggio di una fase. Fail-closed dove si sviluppa, indulgente dove si usa: in test e in
      # sviluppo una fase senza parola solleva subito — è il momento in cui costa meno accorgersene —
      # mentre in produzione ripiega su «in lavorazione», che è vero per quasi tutte le fasi e non è
      # mai il nome interno. Stampare il nome interno su una pagina in italiano era il difetto.
      def self.stage(phase)
        known = STAGE[phase.to_s]
        return known if known

        raise ArgumentError, "fase senza passaggio: #{phase.inspect}" unless Rails.env.production?

        Rails.logger.warn("[CYRA-602] fase senza passaggio: #{phase.inspect}")
        "in_progress"
      end

      # Vero quando quel momento aspetta una decisione di una persona. Riusa l'elenco di sopra invece
      # di ricopiarlo: due elenchi che dicono la stessa cosa divergono, ed è già successo.
      def self.waiting_on_you?(phase) = HUMAN_GATED_PHASES.include?(phase.to_s)


      module_function

      # La fase di UN workflow, dato l'insieme delle sue phase con almeno un tentativo respinto in
      # revisione. L'insieme può mancare (una lista lo passa solo per i workflow che compaiono nella
      # pluck): assente vale nessuna bocciatura.
      def phase(workflow, failed_phases)
        failed_phases ||= Set.new
        return "cancelled" if workflow.cancelled_at?
        return "completed" if workflow.completed_at?
        # Un blocco esplicito vince su tutto quello che segue e deve stare QUI, sopra i cinque rami
        # che lo scavalcherebbero. Il `review_blocked` più in basso non basta: guarda gli attempt
        # bocciati, e un blocco dichiarato dall'agente non ne produce nessuno — la sua consegna è
        # valida e chiude approved. CYRA-598
        return "review_blocked" if workflow.blocked_at?

        return "review_blocked" if (active = active_closer_phase(workflow)) && failed_phases.include?(active)
        # CYRA-624 — consegnata l'etichetta della versione, la lavorazione aspetta la prova che il
        # rilascio sia in piedi. Prima qui non c'era niente perché il ticket era già Fatto.
        return "awaiting_production_proof" if workflow.closer_production_completed_at?
        return "closer_production" if workflow.closer_production_started_at?
        # CYRA-504 — senza il via libera umano la lavorazione non è in coda per la produzione: è
        # ferma ad aspettarlo, ed è la fase che la coda trasforma in card.
        if workflow.closer_staging_verified_at?
          return "closer_production_queued"
        end
        # CYRA-620 — mentre il sistema guarda se il codice approvato è atterrato, la lavorazione
        # ha un nome suo e non chiede niente.
        return "verifying_staging" if workflow.closer_staging_completed_at?
        return "closer_staging" if workflow.closer_staging_started_at?
        return "closer_staging_queued" if workflow.autopilot_approved_at?
        # CYRA-612 — la card arriva nella pila solo dopo che il sistema ha aperto la proposta e
        # letto i controlli su quel codice. Prima bastava che la macchina dicesse «ho finito»: chi
        # approvava si trovava davanti una cosa che il sistema non aveva mai visto.
        return "awaiting_autopilot_approval" if workflow.autopilot_completed_at? && workflow.candidate_verified_at?
        # CYRA-615 — mentre il sistema guarda la proposta la lavorazione ha un nome suo, e non si
        # racconta piu' come lavoro che l'agente sta ancora scrivendo.
        return "verifying_candidate" if workflow.autopilot_completed_at?
        # CYRA-280: il filtro "vale solo la bocciatura su una fase ancora aperta" è UNO SOLO e vive
        # sul modello — qui si passano le phase già precaricate, così la catena resta pura.
        return "review_blocked" if workflow.open_review_failure?(failed_phases)
        return "autopilot" if workflow.autopilot_started_at?
        return "autopilot_queued" if workflow.approved_at?
        return "awaiting_approval" if workflow.planned_at?
        return "planning" if workflow.triaged_at?
        return "triaging" if workflow.triage_started_at?
        return "triage_queued" if workflow.triage_requested_at?

        "inactive"
      end

      # Fase closer "attiva" (avviata, non completata), o nil. Pezzo della catena, quindi vive qui con
      # lei: ritorna la stringa così che il gate review_blocked filtri gli attempt falliti per QUELLA
      # phase — una produzione dopo uno staging chiuso non eredita il fallimento dello staging.
      # closer_production ha precedenza, è la fase più avanzata.
      def active_closer_phase(workflow)
        # CYRA-624 — una produzione consegnata non è più «attiva»: sta aspettando la prova.
        return "closer_production" if workflow.closer_production_started_at? &&
                                      !workflow.closer_production_completed_at?
        return "closer_staging" if workflow.closer_staging_started_at? && !workflow.closer_staging_completed_at?

        nil
      end

      # { workflow_id => Set[phase, …] } delle phase con almeno un attempt respinto in revisione.
      # UNA query pluck per l'intera lista.
      def failed_phases_by_workflow(workflow_ids)
        return {} if workflow_ids.empty?

        phases_by_workflow(::Agents::Attempt.status_review_failed.where(workflow_id: workflow_ids))
      end

      # { workflow_id => Set[phase, …] } delle phase con almeno un tentativo ANCORA APERTO (CYRA-317).
      # Gemello in blocco della seconda pluck di Workflow#stalled_review_phase: una fase respinta su
      # cui c'è già un tentativo in volo non è ferma, sta riprovando.
      def open_phases_by_workflow(workflow_ids)
        return {} if workflow_ids.empty?

        phases_by_workflow(::Agents::Attempt.where(workflow_id: workflow_ids)
                                            .where.not(status: ::Agents::Attempt::TERMINAL_STATUSES))
      end

      # { workflow_id => { phase => attempt_id } } dell'ULTIMO tentativo di ogni fase: è ciò che sta
      # dietro una cella della plancia. UNA pluck per l'intera pagina — per riga sarebbero cinque
      # query a lavorazione. L'ordine crescente più la sovrascrittura fanno vincere il tentativo più
      # recente, che è quello che racconta come sta andando adesso. CYRA-592
      def last_attempts_by_workflow_phase(workflow_ids)
        return {} if workflow_ids.empty?

        ::Agents::Attempt.where(workflow_id: workflow_ids).order(:started_at)
                         .pluck(:workflow_id, :phase, :id)
                         .each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |(workflow_id, phase, id), acc|
          acc[workflow_id][phase] = id
        end
      end

      def phases_by_workflow(scope)
        scope.pluck(:workflow_id, :phase)
             .each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |(workflow_id, phase), acc|
          acc[workflow_id] << phase
        end
      end
    end
  end
end
