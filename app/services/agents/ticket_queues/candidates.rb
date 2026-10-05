# frozen_string_literal: true

module Agents
  module TicketQueues
    # La coda di un progetto per un host: chi ci sta, in che ordine e come si carica lo snapshot da
    # servire. Fonte UNICA dei candidati, condivisa dal preflight in due passi (Next) e dalla presa in
    # carico atomica (ClaimNext): due copie della stessa query sarebbero due code diverse il giorno che
    # una delle due cambia un filtro, e il percorso rimasto indietro consegnerebbe ticket che l'altro
    # considera fuori coda.
    class Candidates
      # Il lock nomina SOLO ticketing_tickets: senza `OF`, PostgreSQL proverebbe a lockare anche il lato
      # nullable della outer join sul lease e rifiuterebbe la query. SKIP LOCKED salta le righe che
      # qualcun altro sta già tenendo (un claim in corso, una modifica ancora aperta) invece di
      # aspettarle: è quello che permette a due chiamate concorrenti di prendere righe diverse anziché
      # contendersi la testa (CYRA-588).
      HEAD_LOCK = "FOR UPDATE OF ticketing_tickets SKIP LOCKED"

      # Il progetto della coda: deve esistere nell'organizzazione, avere un repository GitHub e ricadere
      # nello scope del service account dell'host. Non distingue «non esiste» da «non lo vedi» — il
      # chiamante risponde allo stesso modo in entrambi i casi, per non rivelare progetti fuori scope.
      def self.project_for(organization:, host:, key:)
        key = key.to_s.strip.upcase
        return if key.blank?

        project = organization.projects.includes(:github_repository).find_by(key:)
        project if project&.github_repository && Agents::Hosts::ProjectScope.new(host:).allows?(project)
      end

      def initialize(project:, host:, now: Agents::Leases::Clock.current)
        @project = project
        @host = host
        @now = now
      end

      def head_id = relation.pick(:id)

      def locked_head_id = relation.lock(HEAD_LOCK).pick(:id)

      # Host-first (CYAU-79): reclama la PROSSIMA FASE PRONTA (OR delle 5 via il CASE) e correla il deferral
      # alla fase pronta PER-RIGA (le 5 condizioni ready sono mutuamente esclusive). La guardia cancelled/
      # completed vive dentro il CASE (→ NULL, escluso da `IS NOT NULL`), gemella di Workflow#ready_execution_phase.
      #
      # Gate di eleggibilità agenti (CYRA-184): un ticket raggiunge un host SOLO se marcato allowed.
      # Il filtro vive QUI e non dentro READY_EXECUTION_PHASE_SQL perché l'eleggibilità è proprietà
      # del TICKET, non della fase del workflow: infilarla nel CASE romperebbe la parità Ruby/SQL con
      # Workflow#ready_execution_phase e farebbe restituire NULL per un ticket bloccato — cioè
      # "nessuna fase pronta", che è falso (la fase è pronta, è il ticket a non essere lavorabile).
      def relation
        @project.tickets
                .joins(:status, :priority, :agent_workflow)
                .left_joins(:agent_lease)
                .where(agent_eligibility: :allowed)
                .where.not(types_ticket_statuses: { category: Types::TicketStatus.categories.fetch("done") })
                .where("agents_leases.id IS NULL OR agents_leases.expires_at <= ?", @now)
                .where.not(deferrals.arel.exists)
                .where("(#{ready_phase_sql}) IS NOT NULL")
                .where(frozen_constraint_sql)
                .where.not(blocking_questions.arel.exists)
                .where(prerequisites_met_sql)
                .where(production_slot_free_sql)
                .where(production_hold_released_sql)
                .order(Arel.sql("types_ticket_priorities.position DESC"), :number)
      end

      # CYRA-781 — la coda non prende un ticket che aspetta la risposta a una domanda bloccante.
      #
      # Non si ferma: lo SALTA, come i prerequisiti. La coda prende il primo lavoro buono che c'è
      # sotto e il ticket rientra da sé appena qualcuno risponde — nessuno deve togliere una leva.
      #
      # Sta QUI e non dentro READY_EXECUTION_PHASE_SQL per la stessa ragione già scritta per
      # l'eleggibilità: quel CASE è puro per-riga e ha un gemello Ruby sotto spec; una condizione
      # correlata lì dentro romperebbe la parità e darebbe NULL, cioè «nessuna fase pronta» — che è
      # falso. La fase è pronta: è il ticket ad aspettare una persona.
      #
      # Vale per QUALUNQUE fase, non solo per il triage: una domanda che qualcuno ha dichiarato
      # bloccante lo è per tutto il lavoro su quel ticket, non per il passo in cui è nata.
      def blocking_questions
        Ticketing::Question
          .select(1)
          .where("ticketing_questions.ticket_id = ticketing_tickets.id")
          .where(blocking: true, answered_at: nil, closed_at: nil)
      end

      # CYRA-682 — le fasi che TOCCANO il repository non partono senza il vincolo congelato
      # all'approvazione (su quale archivio può nascere il lavoro, e qual è la prova che dirà «fatto»).
      # È una regola dell'host, ed è giusta: meglio un ticket fermo che una macchina che inventa dove
      # aprire la proposta e se ne accorge alla consegna, a giro già pagato.
      #
      # Il guaio è che l'host la applica DOPO la presa in carico, e la presa in carico marca già la
      # fase come avviata e apre un tentativo. Nessuno lo esegue, il permesso scade, il tentativo muore
      # orfano — e gli orfani contano nel tetto. Due giri e la lavorazione si blocca per sempre. In
      # produzione: 13 lavorazioni bruciate in tre ore, e nessun archivio dei 40 dichiarava la prova.
      #
      # Il server lo sa PRIMA di proporre: il vincolo è scritto sul piano congelato. Quindi non lo
      # propone. Il ticket resta in coda intatto e riparte da sé appena il progetto dichiara la sua
      # prova — nessuno deve sbloccarlo.
      #
      # Sta QUI e non dentro READY_EXECUTION_PHASE_SQL per la stessa ragione del gate di eleggibilità
      # qui sopra: infilarlo nel CASE romperebbe la parità Ruby/SQL e farebbe dire «nessuna fase
      # pronta», che è falso — la fase è pronta, è il vincolo a mancare.
      #
      # Le fasi che leggono non hanno un vincolo da rispettare e restano fuori dal filtro. L'elenco si
      # deriva dal profilo (`write_access?`), non si riscrive: una fase nuova che scrive entra da sé.
      def frozen_constraint_sql
        write_phases = Agents::PhaseProfile::PHASES.select { |phase| Agents::PhaseProfile.fetch(phase).write_access? }
        list = write_phases.map { |phase| ActiveRecord::Base.connection.quote(phase) }.join(", ")
        <<~SQL.squish
          (#{ready_phase_sql}) NOT IN (#{list})
          OR EXISTS (
            SELECT 1 FROM agents_plans
            WHERE agents_plans.id = agents_workflows.frozen_plan_id
              AND agents_plans.candidate_items IS NOT NULL
          )
        SQL
      end

      # CYRA-595 — un rilascio in produzione alla volta per repository. Sta QUI e non dentro
      # READY_EXECUTION_PHASE_SQL per la stessa ragione dell'eleggibilità: il CASE è puro per-riga e
      # ha un gemello Ruby sotto spec. Infilarci una condizione che guarda le ALTRE righe lo
      # renderebbe una query correlata, e la parità con Workflow#ready_execution_phase si romperebbe.
      #
      # La condizione morde solo dove la fase pronta è il rilascio in produzione: le altre fasi
      # continuano in parallelo, perché a essere irreversibile è solo l'ultimo passo.
      # La subquery gira sulla STESSA tabella della query esterna, quindi le serve un alias suo:
      # senza, `agents_workflows` dentro e fuori sarebbero la stessa riga e la condizione non
      # escluderebbe niente. `altri` è il nome dell'insieme «le altre lavorazioni di questo progetto».
      # La condizione morde SOLO dove la fase pronta è il rilascio in produzione. Le altre fasi
      # continuano in parallelo: a essere irreversibile è l'ultimo passo, non la catena.
      # CYRA-623 — la coda non prende i ticket che aspettano un prerequisito. Prima li prendeva: la
      # macchina esaminava, scriveva il piano, una persona lo approvava, la macchina scriveva tutto il
      # codice e apriva la proposta — e solo lì sbatteva contro il cancello. Il giro era già pagato per
      # intero, e su GitHub restava un ramo aperto che nessuno voleva.
      #
      # Non si ferma sul ticket in attesa: lo SALTA, e la coda prende il primo lavoro buono che c'è
      # sotto. E non lo salta per sempre — appena il prerequisito è a posto rientra da solo, senza che
      # nessuno debba togliere una leva.
      #
      # La domanda è quella del cancello, presa dal cancello (`MODE_BY_PHASE`) e valutata con lo
      # stesso criterio (`Connections::TicketDependency.unmet`): una copia scritta qui sarebbe più
      # permissiva o più severa il giorno che una delle due cambia, e nel primo caso il giro di
      # macchina tornerebbe a essere buttato.
      #
      # In SQL e dentro la query che sceglie la testa: un giro in Ruby ticket per ticket costerebbe una
      # query a riga, e la coda la si interroga a ogni richiesta di lavoro. FUORI da
      # READY_EXECUTION_PHASE_SQL, come l'eleggibilità e lo slot di produzione: quel CASE è puro
      # per-riga e ha un gemello Ruby sotto spec; una condizione correlata lì dentro romperebbe la
      # parità e darebbe NULL, cioè «nessuna fase pronta» — che è falso.
      def prerequisites_met_sql
        branches = Ticketing::DependencyGuard::MODE_BY_PHASE.map do |phase, mode|
          "WHEN '#{phase}' THEN NOT EXISTS (#{open_prerequisites(mode).to_sql})"
        end
        <<~SQL.squish
          CASE (#{ready_phase_sql})
            #{branches.join(' ')}
            ELSE NOT EXISTS (#{open_prerequisites(:released).to_sql})
          END
        SQL
      end

      def open_prerequisites(mode)
        Connections::TicketDependency.unmet_for_outer(mode: mode).select(1)
      end

      def production_slot_free_sql
        <<~SQL.squish
          (#{ready_phase_sql}) <> 'closer_production'
          OR NOT EXISTS (#{production_already_running.to_sql})
        SQL
      end

      # CYRA-871 — la produzione aspetta 2 ore di staging senza errori nuovi. Fuori dal CASE per la
      # stessa ragione dello slot qui sopra: la fase è pronta, è il freno a trattenerla.
      def production_hold_released_sql
        <<~SQL.squish
          (#{ready_phase_sql}) <> 'closer_production'
          OR (#{Agents::Workflows::ProductionHold.released_sql(now: @now)})
        SQL
      end

      def production_already_running
        Agents::Workflow
          .select(1)
          .from("agents_workflows AS altri")
          .joins("INNER JOIN ticketing_tickets ON ticketing_tickets.id = altri.ticket_id")
          .where("ticketing_tickets.project_id = ?", @project.id)
          .where(Agents::Workflows::ProductionLock::SQL.gsub("agents_workflows.", "altri."))
          .where("altri.id <> agents_workflows.id")
      end

      def snapshot(id)
        @project.tickets.strict_loading
                # `plans: :approved_by` e non il solo `:plans`: il serializer legge il nome di chi ha
                # approvato il piano, e sotto `strict_loading` un'associazione non precaricata solleva
                # invece di degradare a query — la coda intera diventa «snapshot non disponibile».
                #
                # CYRA-681 — `frozen_plan` è un'associazione DIVERSA da `plans`, e precaricare la
                # seconda non copre la prima: il serializer legge `frozen_plan&.version` e senza
                # questa riga la richiesta muore. Non si vedeva perché finché nessun piano è approvato
                # la chiave esterna è vuota, Rails non fa nessuna query e non c'è niente da vietare —
                # il difetto si sveglia al primo piano congelato, cioè proprio quando il lavoro
                # comincia ad avanzare, e ferma la coda di quel progetto per sempre.
                #
                # Stessa storia per `review_candidate` (il commit approvato che il serializer manda
                # all'host): terza associazione, terza riga qui. Senza, la coda del progetto muore
                # con 500 appena una consegna viene approvata — successo il 2026-09-03 alle 07:17.
                .preload(:status, :priority, :milestone, :platforms, :scenarios, :conditions,
                         { agent_workflow: [ { plans: :approved_by }, :frozen_plan, :review_candidate ] },
                         :assignee, :reporter, :reviewer, comments: :author,
                         project: :github_repository)
                .find(id)
      end

      private

      def ready_phase_sql = Agents::Workflow::READY_EXECUTION_PHASE_SQL

      def deferrals
        Agents::TicketQueueDeferral
          .where("agents_ticket_queue_deferrals.ticket_id = ticketing_tickets.id")
          .where(host_id: @host.id)
          .where("agents_ticket_queue_deferrals.execution_phase = (#{ready_phase_sql})")
          .where("agents_ticket_queue_deferrals.retry_at > ?", @now)
      end
    end
  end
end
