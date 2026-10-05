# frozen_string_literal: true

module Agents
  module Workflows
    # TUTTE le lavorazioni in volo (CYRA-593), comprese quelle che l'agente sta ancora facendo e che
    # non chiedono niente a nessuno. La coda delle approvazioni mostra il solo lavoro che aspetta una
    # decisione: chi vuole sapere chi sta lavorando su cosa, da quanto e dove si è fermato non aveva
    # una pagina che glielo dicesse.
    #
    # "In volo" = né conclusa né annullata, su un ticket ancora aperto. Una lavorazione appesa a un
    # ticket già chiuso è lavoro morto ed esce, come esce dalla coda (CYRA-316): due elenchi che
    # contano la stessa cosa in due modi diversi raccontano due storie.
    #
    # CYRA-665 — il perimetro è quello di CHI RISPONDE di quelle lavorazioni: i progetti di cui si è
    # CTO effettivo (Agents::Workflows::CtoProjects), gli stessi su cui la coda offre le decisioni.
    # Prima bastava vedere il ticket, e in produzione una persona che non governa nessun agente si
    # trovava in cima alla home «dodici vanno avanti da sole» — un numero su cui non poteva fare
    # niente, accanto al link a un elenco che non la riguardava. Chi non risponde di nessun progetto
    # ottiene un elenco vuoto e un conteggio zero: sono i chiamanti a non mostrare affatto il pezzo.
    #
    # Sola lettura → ritorna un value object, non un Result.
    #
    #   Agents::Workflows::InFlight.call(organization:, account:, visible_tickets:, visible_projects:,
    #     page: 1, per: 10, state: "waiting", project: "CYRA", agent: host_id) → Board
    class InFlight < ApplicationService
      # Tetto alle lavorazioni materializzate. Fase e stato si risolvono in Ruby (servono le fasi
      # respinte e quelle ancora aperte), quindi i conteggi sono accurati fino a qui: oltre questo
      # numero di lavorazioni contemporaneamente in volo non c'è una pagina da leggere, c'è un
      # allarme organizzativo.
      CAP = 500

      # I tre stati in cui una lavorazione in volo può trovarsi, nell'ordine dei chip. Sono DISGIUNTI
      # e coprono tutto: la somma dei conteggi torna sempre col totale.
      # `waiting` = aspetta una persona · `running` = l'agente ci sta lavorando o è in coda ·
      # `idle` = esiste ma nessuno l'ha mai avviata.
      STATES = %w[waiting running idle].freeze

      # CYRA-630 — i due stati che NON aspettano nessuno. Sono il perimetro del secondo elenco della
      # pagina delle decisioni: «quante vanno avanti da sole senza chiederti niente». Si deriva da
      # STATES per differenza, non si riscrive: uno stato nuovo finisce da sé o di qua o di là, e non
      # può restare fuori da tutti e due — che è il modo in cui i due numeri smetterebbero di tornare.
      AUTONOMOUS_STATES = (STATES - %w[waiting]).freeze

      # Il nome della vista che questa query alimenta: `/member/home/approvals?view=in_flight`. Sta
      # qui e non nel controller perché a citarlo sono anche le viste dei filtri, e una stringa
      # ripetuta in quattro posti diventa quattro stringhe al primo cambio.
      VIEW = "in_flight"

      # Le fasi che aspettano una DECISIONE UMANA: il vocabolario è quello del dominio (lo stesso che
      # legge la coda delle approvazioni). Se i due divergessero, una riga porterebbe l'azione qui e
      # non comparirebbe là — o il contrario.
      HUMAN_GATED_PHASES = PhaseResolver::HUMAN_GATED_PHASES

      # Un ticket in categoria `done` è concluso: la lavorazione ancora appesa è lavoro morto. La
      # categoria è un enum FISSO (open/in_progress/done), non la label editabile dall'org.
      DONE_CATEGORY = ::Types::TicketStatus.categories.fetch("done")

      # Una riga: la lavorazione, dove vive, chi la sta facendo e a che punto è.
      # `host_seconds` e `last_status` sono nil finché nessun tentativo è partito — nil ≠ zero.
      # CYRA-626 — quello che il sistema non riesce a leggere, e quando ci riprova. `nil` quando non
      # c'è niente da dire: la riga tace, invece di raccontare un guasto che non c'è.
      RetryHint = Data.define(:code, :at)

      # CYRA-871 — `production_hold`: perché un rilascio pronto aspetta la produzione, o nil.
      Row = Data.define(:workflow, :ticket, :project, :host, :phase, :state,
                        :last_status, :host_seconds, :last_at, :decidable, :retry_hint,
                        :production_hold) do
        # La riga aspetta una persona? È l'unico caso in cui ha senso offrire un'azione.
        def waiting? = state == "waiting"
      end

      # `page` = Pagination::Result delle righe (la vista usa Ui::PaginationComponent senza sapere
      # che sotto c'è un'aggregazione); `totals` = conteggio per stato, calcolato PRIMA del filtro di
      # stato così le chip restano tutte cliccabili; `total` = somma di `totals`, un numero solo,
      # impossibile da sfasare. `projects`/`agents` = ciò che è presente in elenco, per i filtri.
      Board = Data.define(:page, :total, :totals, :state, :projects, :project, :agents, :agent) do
        def any? = total.positive?
      end

      def initialize(organization:, account:, visible_tickets:, visible_projects:, page: 1,
                     per: Pagination::DEFAULT_PER, state: nil, project: nil, agent: nil,
                     autonomous: false, now: Time.current)
        @organization = organization
        @account = account
        @visible_tickets = visible_tickets
        @visible_projects = visible_projects
        @page = page
        @per = per
        # Un valore fuori vocabolario vale come nessun filtro: una pagina di sola lettura non deve
        # svuotarsi (né esplodere) per una query string sbagliata.
        # Nel perimetro autonomo il vocabolario si stringe con lui: chiedere «aspetta te» qui non deve
        # aprire una finestra sull'altro elenco, e vale come nessun filtro.
        @autonomous = autonomous
        @state = state.to_s.presence_in(@autonomous ? AUTONOMOUS_STATES : STATES)
        @project = project.to_s.presence
        @agent = agent.to_s.presence
        @now = now
      end

      def call
        rows = build_rows(workflows)
        # Il taglio del perimetro viene PRIMA di ogni conteggio: le chip, i progetti, gli agenti e il
        # totale devono parlare della sola vista aperta, o il numero in alto conterebbe righe che
        # l'elenco sotto non mostra.
        rows = rows.reject(&:waiting?) if @autonomous
        # I conteggi si calcolano DOPO i filtri progetto/agente (il numero in alto segue il filtro,
        # scenario 3) ma PRIMA di quello di stato: le chip degli altri stati devono restare visibili
        # anche mentre una è accesa.
        projects = rows.filter_map(&:project).uniq.sort_by(&:key)
        project = projects.map(&:key).include?(@project) ? @project : nil
        rows = rows.select { |row| row.project&.key == project } if project

        agents = rows.filter_map(&:host).uniq.sort_by(&:hostname)
        agent = agents.map { |host| host.id.to_s }.include?(@agent) ? @agent : nil
        rows = rows.select { |row| row.host&.id.to_s == agent } if agent

        totals = rows.group_by(&:state).transform_values(&:size)
        visible = @state ? rows.select { |row| row.state == @state } : rows

        Board.new(page: Pagination.from_array(visible, page: @page, per: @per),
                  total: totals.values.sum, totals: totals, state: @state,
                  projects: projects, project: project, agents: agents, agent: agent)
      end

      # Le lavorazioni in volo dei ticket visibili, sui soli progetti di cui rispondo. Il progetto e lo
      # status arrivano precaricati: la riga li legge entrambi e chiederli per riga sarebbe un N+1 in
      # una lista da centinaia. Il taglio CTO gira in SQL, prima di materializzare: è lo stesso
      # perimetro della coda delle decisioni, e riscriverlo qui vorrebbe dire due numeri diversi
      # sulla stessa pagina al primo cambio.
      def workflows
        ::Agents::Workflow
          .where(ticket_id: @visible_tickets.select(:id), cancelled_at: nil, completed_at: nil)
          .joins(ticket: :status)
          .where.not(types_ticket_statuses: { category: DONE_CATEGORY })
          .where(ticketing_tickets: { project_id: cto_projects.select(:id) })
          .order(updated_at: :desc)
          .limit(CAP)
          .preload(ticket: [ :project, :status ])
          .to_a
      end

      # I progetti di cui sono CTO effettivo, memoizzati: la relation resta una subquery, mai un
      # elenco di id materializzato.
      def cto_projects
        @cto_projects ||= CtoProjects.scope(account: @account, organization: @organization,
                                            visible_projects: @visible_projects)
      end

      # CYRA-630 — il solo NUMERO, senza costruire le righe. La pagina delle decisioni lo mostra
      # accanto al primo a ogni caricamento, e per un numero non servono né i tentativi, né gli host,
      # né le frasi di riprova: sono tre letture in blocco e cinquecento oggetti buttati via subito.
      # Resta il minimo che serve a dire chi aspetta una persona — la fase e le domande aperte.
      def self.autonomous_count(organization:, account:, visible_tickets:, visible_projects:)
        new(organization:, account:, visible_tickets:, visible_projects:, autonomous: true).autonomous_count
      end

      def autonomous_count
        rows = workflows
        ids = rows.map(&:id)
        failed = PhaseResolver.failed_phases_by_workflow(ids)
        open = PhaseResolver.open_phases_by_workflow(ids)
        asking_ids = workflows_asking(ids)

        rows.count do |workflow|
          phase = PhaseResolver.phase(workflow, failed[workflow.id])
          state_for(workflow, phase, failed[workflow.id], open[workflow.id],
                    asking: asking_ids.include?(workflow.id)) != "waiting"
        end
      end

      private

      def build_rows(workflows)
        ids = workflows.map(&:id)
        failed = PhaseResolver.failed_phases_by_workflow(ids)
        open = PhaseResolver.open_phases_by_workflow(ids)
        aggregates = aggregates_by_workflow(ids)
        # CYRA-630 — chi ha una domanda senza risposta aspetta una persona, e la coda delle decisioni
        # lo conta. La FASE non lo dice: una lavorazione con una domanda in sospeso resta in una fase
        # di lavoro, e senza questa lettura la stessa riga finirebbe nei due elenchi e nei due numeri.
        asking_ids = workflows_asking(ids)
        # CYRA-626 — due letture in blocco per l'intera pagina, mai una per riga: la frase la vedono
        # venticinque righe insieme, e una query a riga la pagherebbe chi apre l'elenco.
        hints = retry_hints_by_workflow(ids)
        # Gli host si caricano in UNA query per l'intera pagina: sia quelli dell'ultimo tentativo,
        # sia quelli attribuiti sul workflow (che servono alle righe senza nessun tentativo).
        hosts = hosts_by_id(aggregates.values.filter_map { |row| row[:host_id] } +
                            workflows.filter_map { |workflow| attributed_host_id(workflow) })

        phases = workflows.to_h { |workflow| [ workflow.id, PhaseResolver.phase(workflow, failed[workflow.id]) ] }
        holds = production_holds(workflows.select { |workflow| phases[workflow.id] == "closer_production_queued" })

        rows = workflows.map do |workflow|
          phase = phases.fetch(workflow.id)
          aggregate = aggregates[workflow.id] || {}
          Row.new(workflow: workflow, ticket: workflow.ticket, project: workflow.ticket.project,
                  host: hosts[aggregate[:host_id] || attributed_host_id(workflow)],
                  phase: phase,
                  state: state_for(workflow, phase, failed[workflow.id], open[workflow.id],
                                   asking: asking_ids.include?(workflow.id)),
                  last_status: aggregate[:last_status],
                  host_seconds: aggregate[:host_seconds],
                  last_at: aggregate[:last_at] || workflow.updated_at,
                  decidable: decidable?(workflow, phase),
                  retry_hint: retry_hint_for(workflow, phase, hints),
                  production_hold: holds[workflow.id])
        end
        # Dalla lavorazione toccata per ultima, come la tabella dei ticket lavorati della scheda
        # agente: chi apre la pagina vuole sapere cosa sta succedendo adesso.
        rows.sort_by { |row| row.last_at || row.workflow.updated_at }.reverse
      end

      # CYRA-871 — il freno per le righe in attesa della produzione: l'attesa delle 2 ore si legge dalla
      # riga, gli errori nuovi in staging con UNA query per la pagina, sullo stesso predicato della coda.
      def production_holds(waiting)
        return {} if waiting.empty?

        now = Time.current
        soaking, past = waiting.partition { |workflow| now < workflow.closer_staging_verified_at + ProductionHold::WINDOW }
        holds = soaking.to_h do |workflow|
          [ workflow.id, { reason: "staging_soak", until: workflow.closer_staging_verified_at + ProductionHold::WINDOW } ]
        end
        return holds if past.empty?

        ::Agents::Workflow.joins(:ticket).where(id: past.map(&:id))
                          .where.not(ProductionHold.released_sql(now:)).pluck(:id)
                          .each { |id| holds[id] = { reason: "staging_errors" } }
        holds
      end

      # CYRA-626 — quando il sistema non riesce a leggere una cosa su GitHub, la lavorazione si
      # ferma e nessuno lo viene a sapere: la riga continua a dire «va avanti da sola», col pallino
      # che pulsa, e l'ultimo esito resta verde. Dall'esterno una lavorazione che sta lavorando e una
      # congelata da un guasto di rete si vedono identiche.
      #
      # La sorgente sono le colonne che nascono comunque — la riga del candidato e quella della prova
      # di rilascio — e MAI i rinvii della coda: quelli li scrive l'host con tre motivi che non
      # riguardano GitHub, e uno di quelli («serve un chiarimento») stamperebbe «GitHub non risponde»
      # su un ticket che sta aspettando una persona.
      def retry_hints_by_workflow(workflow_ids)
        return {} if workflow_ids.empty?

        now = Time.current
        collected = {}
        ::Agents::DeliveryCandidate.where(workflow_id: workflow_ids, state: :unreachable)
                                   .where.not(last_error_code: nil).where(next_check_at: now..)
                                   .pluck(:workflow_id, :last_error_code, :next_check_at)
                                   .each { |id, code, at| collected[[ id, :candidate ]] = RetryHint.new(code:, at:) }
        ::Agents::WorkflowProbe.where(workflow_id: workflow_ids, closed_at: nil)
                               .where.not(last_error_code: nil).where(next_check_at: now..)
                               .pluck(:workflow_id, :last_error_code, :next_check_at)
                               .each { |id, code, at| collected[[ id, :probe ]] = RetryHint.new(code:, at:) }
        collected
      end

      # La frase compare solo dove è vera: mai su una lavorazione che aspetta una persona, mai su una
      # che si è fermata davvero. Confonderle sarebbe peggio che tacere — «riprovo alle 15:40» su un
      # lavoro che aspetta una tua risposta ti fa aspettare per sempre.
      def retry_hint_for(workflow, phase, hints)
        return nil if workflow.blocked_at? || HUMAN_GATED_PHASES.include?(phase)

        hints[[ workflow.id, phase == "awaiting_production_proof" ? :probe : :candidate ]]
      end

      # Lo stato della riga. `review_blocked` è l'unica fase che si sdoppia (CYRA-317): ferma davvero
      # — e allora aspetta una persona — oppure già in nuovo tentativo, e allora sta lavorando. Il
      # discrimine è lo STESSO della coda, letto dalle fasi precaricate invece che con due query per
      # riga (Workflow#stalled_review_phase_from).
      def state_for(workflow, phase, failed_phases, open_phases, asking: false)
        # Prima di tutto il resto: una domanda in sospeso aspetta una persona qualunque sia la fase.
        return "waiting" if asking

        return "idle" if phase == "inactive"
        return "running" unless HUMAN_GATED_PHASES.include?(phase)
        return "waiting" unless phase == "review_blocked"
        return "waiting" if workflow.blocked_at?

        workflow.stalled_review_phase_from(failed_phases.to_a, open_phases.to_a) ? "waiting" : "running"
      end

      # Gli id delle lavorazioni con una domanda ancora senza risposta. UNA query per l'intera pagina,
      # con la stessa condizione della coda delle decisioni (`answered_at` e non la FK del commento,
      # CYRA-219): due condizioni diverse per la stessa domanda farebbero comparire la riga in tutti e
      # due gli elenchi, o in nessuno.
      def workflows_asking(workflow_ids)
        return Set.new if workflow_ids.empty?

        ::Agents::Clarification.where(workflow_id: workflow_ids, answered_at: nil).distinct.pluck(:workflow_id).to_set
      end

      # L'azione si offre solo dove premerla ha un effetto: decidere su una lavorazione è del CTO
      # effettivo del progetto (Agents::Workflows::CtoGate), e mostrare il pulsante a chiunque veda
      # il ticket sarebbe una promessa che la coda poi non mantiene.
      def decidable?(workflow, phase)
        return false unless HUMAN_GATED_PHASES.include?(phase)

        project = workflow.ticket.project
        (project.cto_id || @organization.cto_id) == @account.id
      end

      # Il tempo dell'agente comprende il tentativo ANCORA APERTO, contato fino ad adesso: una
      # lavorazione partita venti minuti fa non ha lavorato zero secondi, e un vuoto la farebbe
      # sembrare ferma. `last_at` usa COALESCE per lo stesso motivo: un tentativo interrotto senza
      # istante di fine deve comunque poter datare la riga.
      def aggregates_by_workflow(workflow_ids)
        return {} if workflow_ids.empty?

        ::Agents::Attempt.where(workflow_id: workflow_ids).group(:workflow_id)
                         .pluck(Arel.sql("agents_attempts.workflow_id"), *aggregate_selects)
                         .to_h do |workflow_id, host_seconds, last_at, status_id, host_id|
          [ workflow_id, { host_seconds: host_seconds&.to_f&.round, last_at: last_at,
                           last_status: ::Agents::Attempt.statuses.key(status_id), host_id: host_id } ]
        end
      end

      def aggregate_selects
        [
          Arel.sql(sanitize("SUM(EXTRACT(EPOCH FROM (COALESCE(agents_attempts.finished_at, :now) - agents_attempts.started_at)))")),
          Arel.sql(sanitize("MAX(COALESCE(agents_attempts.finished_at, agents_attempts.started_at))")),
          Arel.sql("(ARRAY_AGG(agents_attempts.status ORDER BY agents_attempts.started_at DESC))[1]"),
          Arel.sql("(ARRAY_AGG(agents_attempts.host_id ORDER BY agents_attempts.started_at DESC))[1]")
        ]
      end

      def sanitize(sql) = ::Agents::Attempt.sanitize_sql_array([ sql, { now: @now } ])

      def hosts_by_id(ids)
        ids = ids.compact.uniq
        return {} if ids.empty?

        ::Agents::Host.where(organization_id: @organization.id, id: ids).index_by(&:id)
      end

      # Chi la sta facendo quando nessun tentativo è ancora partito: la catena unica del workflow
      # (CYRA-689), condivisa con la coda delle approvazioni. Nil resta nil — la riga dirà
      # "non registrato", che è la verità di una lavorazione appena messa in coda.
      def attributed_host_id(workflow) = workflow.attributed_host_id
    end
  end
end
