# frozen_string_literal: true

module Home
  module Approvals
    # La coda delle decisioni che aspettano QUESTO account: quattro sorgenti di dominio fuse per età,
    # le più vecchie in cima. È l'unico posto in cui quelle query e i loro gate vivono — la card della
    # home la chiama con `limit: 5`, la pagina Approvazioni senza limite. Sola lettura, quindi ritorna
    # un value object e non un Result. CYRA-262
    class Queue < ApplicationService
      include Rails.application.routes.url_helpers

      # Tetto della pila quando nessun limite è richiesto. Oltre non si carica: una coda di decisioni
      # più lunga di così non è una giornata di lavoro, è un allarme organizzativo.
      PAGE_LIMIT = 100

      # Tetto ai workflow agente letti, lo STESSO dell'elenco delle lavorazioni in volo: due soglie
      # diverse farebbero esistere una lavorazione in una pagina e non nell'altra. Vale su una lettura
      # LEGGERA (il contorno si precarica sulle sole righe che finiscono in pagina), quindi protegge
      # dal carico senza decidere quali filtri esistano. CYRA-790
      CANDIDATE_CAP = ::Agents::Workflows::InFlight::CAP

      # Le fasi che aspettano una DECISIONE UMANA; il resto è lavoro in corso dell'agente e non compare
      # in coda. Il vocabolario vive nel dominio perché a leggerlo sono due elenchi — questa coda e
      # quello delle lavorazioni in volo — e due copie divergerebbero al primo stato nuovo. L'ordine
      # conta: STATES ne deriva ed è l'ordine dei chip dei filtri. CYRA-593
      HUMAN_GATED_PHASES = ::Agents::Workflows::PhaseResolver::HUMAN_GATED_PHASES

      # Gli STATI su cui la pagina filtra e conta, nell'ordine dei chip. Più fini delle famiglie: le tre
      # fasi degli automi si decidono in modi diversi, quindi valgono come tre stati. `waiting` è
      # l'unico trasversale e VINCE sulla famiglia (#with_waiting), così gli stati restano disgiunti e
      # la somma dei conteggi torna col totale. CYRA-290
      WAITING_STATE = "waiting"
      STATES = (HUMAN_GATED_PHASES + %W[review clarification secret_change #{WAITING_STATE}]).freeze

      # `review_blocked` non è una cosa sola: se la fase respinta è rimasta ferma serve una persona e la
      # riga resta in coda; se riparte da sé la lavorazione sta GIÀ riprovando e non chiede niente a
      # nessuno. Quelle vivono in uno stato loro, fuori dal totale e dalla pila, in un elenco separato
      # da cui restano chiudibili a mano. CYRA-317
      RETRYING_STATE = "retrying"

      # Il vocabolario che il parametro `state` accetta: le sole chip della riga dei filtri. `retrying`
      # non c'è — quelle righe escono comunque da coda e conteggi, ma il loro elenco lo serve
      # `Agents::Workflows::InFlight`, che ha un perimetro più largo. CYRA-630
      FILTERABLE_STATES = STATES

      # CYRA-316 — un ticket in categoria `done` (Resolved/Closed nei default) è concluso: una decisione
      # che lo aspetta è lavoro morto, quindi le righe legate a un ticket done escono dalla coda e dai
      # conteggi. La categoria è un enum FISSO (open/in_progress/done), non la label editabile dall'org,
      # perciò "quali stati contano come finali" è definito una volta per tutte, per ogni progetto.
      DONE_CATEGORY = Types::TicketStatus.categories.fetch("done")

      # Pre-filtro SQL dei candidati agent_plan: solo i workflow che POSSONO essere in una fase
      # human-gated — piano generato, autopilot completato, un closer avviato, una review fallita o un
      # blocco scritto. Tiene fuori il triage/planning automatico, che è la maggioranza; `blocked_at`
      # è l'unica condizione che prende chi è stato fermato in triage. CYRA-598
      CANDIDATE_AGENT_PLAN_SQL = <<~SQL.squish.freeze
        agents_workflows.planned_at IS NOT NULL
        OR agents_workflows.autopilot_completed_at IS NOT NULL
        OR agents_workflows.closer_staging_started_at IS NOT NULL
        OR agents_workflows.closer_production_started_at IS NOT NULL
        OR agents_workflows.id IN (SELECT workflow_id FROM agents_attempts WHERE status = :review_failed)
        OR agents_workflows.blocked_at IS NOT NULL
      SQL

      # Il COALESCE di #attributed_host_id, ricalcato in SQL: è la macchina che una riga si vedrebbe
      # ATTRIBUITA, non una che ha sfiorato. Ci si appoggiano le tre espressioni qui sotto.
      ATTRIBUTED_HOST_SQL = <<~SQL.squish.freeze
        agents_workflows.closer_production_by_host_id, agents_workflows.closer_staging_by_host_id,
        agents_workflows.autopilot_by_host_id, agents_workflows.planned_by_host_id,
        agents_workflows.triage_by_host_id
      SQL

      # Pre-filtro SQL della macchina scelta: le tre attribuzioni possibili in fase human-gated (piano,
      # autopilot, ricaduta di HOST_BY_PHASE). Resta un sovrainsieme — quale valga dipende dalla fase,
      # che si risolve in Ruby — ma NON prende chi ha solo sfiorato la riga: prendendolo, il tetto si
      # riempirebbe di lavorazioni passate ad altri e il taglio deciderebbe di nuovo cosa si vede.
      CANDIDATE_AGENT_HOST_SQL = <<~SQL.squish.freeze
        COALESCE(agents_workflows.planned_by_host_id, #{ATTRIBUTED_HOST_SQL}) = :host
        OR COALESCE(agents_workflows.autopilot_by_host_id, #{ATTRIBUTED_HOST_SQL}) = :host
        OR COALESCE(#{ATTRIBUTED_HOST_SQL}) = :host
      SQL

      # Cosa risponde una sorgente che il filtro acceso ha svuotato in partenza: nessuna riga, nessun
      # conteggio, nessuna macchina — ma i progetti del suo perimetro PIENO restano, o accendere un
      # filtro toglierebbe dal menu la strada per spegnerlo. CYRA-790
      EMPTY_SOURCE = { items: [], totals: {}, agents: [] }.freeze

      # `items` già ordinati, filtrati e tagliati; `total` = conteggio pieno della vista aperta (non
      # scende accendendo un filtro di stato); `totals` = conteggio per stato; `filter` = lo stato
      # acceso, validato contro FILTERABLE_STATES, o nil; `projects` e `agents` = le scelte dei menu;
      # `project`/`agent` = il filtro acceso, validato contro il perimetro, o nil. CYRA-319, CYRA-448
      Batch = Data.define(:items, :total, :totals, :filter, :projects, :project, :agents, :agent) do
        def any? = total.positive?
      end

      def initialize(account:, organization:, visible_projects:, visible_tickets:, limit: nil, state: nil,
                     project: nil, agent: nil)
        @account = account
        @organization = organization
        @visible_projects = visible_projects
        @visible_tickets = visible_tickets
        @limit = limit || PAGE_LIMIT
        # Solo uno stato del vocabolario: una query string inventata torna a "Tutte" invece di far
        # esplodere (o svuotare) una pagina di sola lettura.
        @filter = state.to_s.presence_in(FILTERABLE_STATES)
        # Una sigla inventata vale come nessun filtro: una coda di sola lettura non deve svuotarsi
        # (ne esplodere) per una query string sbagliata, esattamente come per lo stato.
        @project = project.to_s.presence
        @agent = agent.to_s.presence
      end

      # Tre tempi, in quest'ordine: ANNOTA (chi aspetta risposta passa a `waiting`), CONTA per stato,
      # poi FILTRA e taglia — le chip restano tutte visibili anche con una sola accesa. `totals` parte
      # dai conteggi PIENI delle sorgenti e non dalle righe materializzate, che sono al più `@limit` e
      # mostrerebbero il tetto invece del vero; `total` è la loro somma, impossibile da sfasare.
      def call
        sources = [ clarification_source, review_source, agent_plan_source, secret_change_source ]
        items = with_waiting(sources.flat_map { |source| source.fetch(:items) })
        totals = totals_by_state(sources)
        # Chi riprova da solo non aspetta nessuno: esce QUI, prima di ogni altro conteggio, così chip
        # di stato, progetto, agente e totale parlano della sola coda delle decisioni. Dove va a finire
        # non è affare di questa classe — lo raccoglie l'elenco di ciò che va avanti da solo, che ha
        # una query sua. CYRA-317, CYRA-630
        totals.delete(RETRYING_STATE)
        items = items.reject { |item| item.state == RETRYING_STATE }
        visible = @filter ? items.select { |item| item.state == @filter } : items
        Batch.new(items: order(visible).first(@limit), total: totals.values.sum,
                  totals: totals, filter: @filter,
                  projects: choosable_projects(sources), project: project_filter&.key,
                  agents: choosable_agents(sources), agent: agent_filter&.id&.to_s)
      end

      private

      # Il progetto acceso, risolto contro i progetti che VEDO e non contro le righe caricate: un
      # progetto visibile è un filtro legittimo anche quando le sue decisioni cadono oltre il taglio,
      # e a un progetto senza decisioni si risponde con la coda vuota. Nil = nessun filtro. CYRA-790
      def project_filter
        return @project_filter if defined?(@project_filter)

        @project_filter = (@visible_projects.find_by(key: @project) if @project)
      end

      # La macchina accesa, risolta contro gli host dell'organizzazione sulla mappa già caricata per
      # attribuire i nomi. Il lookup è per STRINGA: un identificativo inventato non è un uuid e
      # chiederlo al database solleverebbe invece di valere «nessun filtro». CYRA-790
      def agent_filter
        return @agent_filter if defined?(@agent_filter)

        @agent_filter = (agent_hosts_by_id[@agent] if @agent)
      end

      def agent_hosts_by_id
        @agent_hosts_by_id ||= ::Agents::Host.where(organization_id: @organization.id)
                                             .index_by { |host| host.id.to_s }
      end

      # I progetti con righe in coda, letti sul perimetro PIENO di ogni sorgente: derivarli dalle
      # righe materializzate faceva sparire dal menu il progetto le cui decisioni cadevano oltre il
      # taglio, e con esso l'unica strada per raggiungerle. Il filtro acceso resta in elenco anche a
      # coda vuota, o smaltita l'ultima riga non si potrebbe più spegnere. CYRA-790
      def choosable_projects(sources)
        ids = sources.flat_map { |source| source.fetch(:project_ids) }.uniq
        ids |= [ project_filter.id ] if project_filter
        return [] if ids.empty?

        @visible_projects.where(id: ids).map { |project| project_ref(project) }.sort_by(&:key)
      end

      # Le macchine con qualcosa in sospeso, sul perimetro del solo filtro progetto: scegliendo un
      # progetto il menu dice chi lavora LÌ, ma accendere una macchina non cancella le altre. Come
      # per i progetti, quella accesa resta in elenco anche a coda vuota. CYRA-790
      def choosable_agents(sources)
        agents = sources.flat_map { |source| source.fetch(:agents) }.uniq(&:id)
        if agent_filter && agents.none? { |candidate| candidate.id == agent_filter.id }
          agents += [ Feed::AgentRef.new(id: agent_filter.id, name: agent_filter.hostname) ]
        end
        agents.sort_by(&:name)
      end

      # La macchina che ha prodotto CIÒ CHE ASPETTA una decisione: il piano da chi ha pianificato, il
      # lavoro consegnato da chi l'ha eseguito, una lavorazione ferma dall'ultima che ci ha provato —
      # la stessa catena dell'elenco in volo, così le due schermate dicono lo stesso nome. Le righe
      # storiche senza host restano in coda senza agente, non spariscono. CYRA-689
      HOST_BY_PHASE = { "awaiting_approval" => :planned_by_host_id,
                        "awaiting_autopilot_approval" => :autopilot_by_host_id }.freeze

      def agent_ref_for(workflow, phase)
        host_id = workflow.public_send(HOST_BY_PHASE[phase]) if HOST_BY_PHASE.key?(phase)
        host_id ||= workflow.attributed_host_id
        return nil if host_id.blank?

        host = agent_hosts_by_id[host_id.to_s]
        host && Feed::AgentRef.new(id: host.id, name: host.hostname)
      end

      # Una sola ProjectRef per progetto: la riga la usa per la sigla col nome esteso, il menu per la
      # voce da scegliere. Memoizzata per id, così le due strade non producono doppioni.
      def project_ref(project)
        @project_refs ||= {}
        @project_refs[project.id] ||= Feed::ProjectRef.new(key: project.key, name: project.name)
      end

      # Conteggi pieni per stato: quelli dichiarati dalle sorgenti, meno le righe che #with_waiting ha
      # spostato sotto `waiting` — quindi va chiamato DOPO di lui. Uno stato svuotato sparisce, la sua
      # chip non compare a zero. Scostamento dichiarato: `waiting` si riconosce solo sulle righe
      # materializzate, quindi oltre il tetto di una sorgente qualcuna resta contata nella famiglia.
      def totals_by_state(sources)
        totals = Hash.new(0)
        sources.each { |source| source.fetch(:totals).each { |state, count| totals[state] += count } }
        @reclassified.to_h.each do |state, count|
          totals[state] -= count
          totals[WAITING_STATE] += count
        end
        totals.reject { |_, count| count.zero? }
      end

      # Ordine di coda: prima ciò che aspetta ME (FIFO, i più vecchi in cima), in fondo ciò a cui ho
      # già chiesto precisazioni — lì la palla è a qualcun altro, tenerlo in cima falserebbe la pila.
      def order(items)
        items.sort_by { |item| [ item.waiting_since ? 1 : 0, item.sort_at ] }
      end

      # L'agente ha chiesto e aspetta risposta: rispondere sblocca la lavorazione. Il predicato è
      # `answered_at` e non la FK del commento, che è a nullify — cancellare la propria risposta
      # rifarebbe comparire la domanda. Va a CHI DEVE RISPONDERE, il revisore del ticket, non a
      # chiunque lo veda: una domanda mostrata a tutti non è mostrata a nessuno. CYRA-219, CYRA-665
      def clarification_source
        base = Agents::Clarification.where(answered_at: nil)
                                    .joins(workflow: { ticket: :status })
                                    .where(agents_workflows: { ticket_id: visible_ticket_ids })
                                    .where(ticketing_tickets: { reviewer_id: @account.id })
                                    .where.not(types_ticket_statuses: { category: DONE_CATEGORY })
        # Le scelte del menu vengono dal perimetro pieno, prima di qualunque taglio. Una domanda non
        # porta il nome di una macchina: col filtro agente acceso esce tutta la famiglia. CYRA-790
        project_ids = base.distinct.pluck(Arel.sql("ticketing_tickets.project_id"))
        return EMPTY_SOURCE.merge(project_ids: project_ids) if agent_filter

        base = base.where(ticketing_tickets: { project_id: project_filter.id }) if project_filter
        rows = base.order(:created_at).limit(@limit).preload(workflow: { ticket: [ :project, :status ] })
        items = rows.map do |clarification|
          ticket = clarification.workflow.ticket
          track_ticket("clarification:#{clarification.id}", ticket.id)
          item(
            kind: :clarification, icon: "circle-question-mark", tone: :amber,
            title: t("clarification.title", code: ticket.code),
            subtitle: clarification.questions.first, code: ticket.code,
            meta: ticket.project.key, project: project_ref(ticket.project),
            url: member_ticket_path(ticket), sort_at: clarification.created_at,
            dom_id: "home_clarification_#{clarification.id}", key: "clarification:#{clarification.id}",
            state: "clarification", ticket_status: ticket_status_badge(ticket)
          )
        end
        { items: items, totals: { "clarification" => base.count }, project_ids: project_ids, agents: [] }
      end

      # Ticket in uno status review-gate di cui sono il revisore designato. La condizione NON è scritta
      # qui: sta in Ticketing::Ticket.awaiting_review_by, la stessa del contatore «Aspettano te» in
      # testa a board e lista — riscriverla in due posti darebbe due numeri per la stessa
      # domanda. CYRA-374
      def review_source
        base = @visible_tickets.awaiting_review_by(@account)
        # CYRA-1066 — a ticket whose approved run is still closing is not a review to decide: the
        # closers resolve it once production is up, and Approve here would resolve it first.
        base = base.where.not(id: ::Agents::Workflow.closing.select(:ticket_id))
        # Perimetro pieno per le scelte, poi il filtro progetto; una review non porta il nome di una
        # macchina, quindi col filtro agente acceso la famiglia esce intera. CYRA-790
        project_ids = base.distinct.pluck(:project_id)
        return EMPTY_SOURCE.merge(project_ids: project_ids) if agent_filter

        base = base.where(project_id: project_filter.id) if project_filter
        # Ordine ASC (più in review da tempo = più urgenti in cima): coerente col merge FIFO e con le
        # altre sorgenti — pre-tagliare i più recenti nasconderebbe i ticket fermi da più tempo.
        rows = base.order(:updated_at).limit(@limit).includes(:project, :status)
        # Una query per pagina, non per riga: quali hanno un lavoro consegnato da leggere. CYRA-863
        reported_ids = Ticketing::Report.delivered.where(ticket_id: rows.map(&:id)).distinct.pluck(:ticket_id).to_set
        items = rows.map do |ticket|
          track_ticket("review:#{ticket.id}", ticket.id)
          item(
            kind: :review, icon: "clipboard-check", tone: :indigo,
            title: t("review.title", code: ticket.code),
            subtitle: ticket.title, code: ticket.code,
            meta: ticket.project.key, project: project_ref(ticket.project),
            url: member_ticket_path(ticket), sort_at: ticket.updated_at,
            dom_id: "home_review_#{ticket.id}", key: "review:#{ticket.id}", state: "review",
            bulk_approvable: can_manage_ticket?(ticket.project),
            ticket_status: ticket_status_badge(ticket), no_report: reported_ids.exclude?(ticket.id)
          )
        end
        { items: items, totals: { "review" => base.count }, project_ids: project_ids, agents: [] }
      end

      # Workflow agente in fase human-gated, e solo le decisioni riservate al CTO effettivo: il gate
      # gira in SQL, prima di materializzare. Tre perimetri, una lettura ciascuno e memoizzata (senza
      # filtri accesi coincidono, quindi una sola): le RIGHE vogliono progetto e macchina insieme, il
      # menu dei progetti li vuole entrambi spenti, quello delle macchine il solo progetto. CYRA-790
      def agent_plan_source
        gated = gated_agent_workflows(project: project_filter, agent: agent_filter)
        shown = preloaded(gated.first(@limit))
        # CYRA-998 — the version a rewritten plan has reached, one query for the whole page.
        plan_versions = ::Agents::Plan.where(workflow_id: shown.map { |workflow, _, _| workflow.id })
                                      .group(:workflow_id).maximum(:version)
        items = shown.map do |workflow, phase, state|
          ticket = workflow.ticket
          track_ticket("agent_plan:#{workflow.id}", ticket.id)
          item(
            kind: :agent_plan,
            icon: PLAN_ICONS.fetch(state, "workflow"),
            tone: PLAN_TONES.fetch(state, :indigo),
            title: t("agent_plan.#{state}.title", code: ticket.code),
            subtitle: ticket.title, code: ticket.code,
            meta: ticket.project.key, project: project_ref(ticket.project),
            url: member_ticket_path(ticket), sort_at: workflow.updated_at,
            dom_id: "home_agent_plan_#{workflow.id}", key: "agent_plan:#{workflow.id}",
            state: state,
            agent: agent_ref_for(workflow, phase),
            bulk_approvable: plan_bulk_approvable?(phase, ticket),
            ticket_status: ticket_status_badge(ticket),
            # CYRA-610 — solo su un piano DA approvare: sulle altre fasi la decisione è già stata
            # presa (o congelata), e un avviso su qualcosa che non si sta più decidendo è rumore.
            freeze_warning: (plan_freeze_warning(ticket) if phase == "awaiting_approval"),
            plan_version: plan_versions[workflow.id]
          )
        end
        # Conteggi su TUTTI i gated, non sui primi @limit: è l'unica sorgente che li ha già in memoria.
        { items: items, totals: gated.group_by(&:last).transform_values(&:size),
          project_ids: in_queue(gated_agent_workflows(project: nil, agent: nil))
                         .map { |workflow, _, _| workflow[:gated_project_id] }.uniq,
          agents: in_queue(gated_agent_workflows(project: project_filter, agent: nil))
                    .filter_map { |workflow, phase, _| agent_ref_for(workflow, phase) }.uniq(&:id) }
      end

      # Solo ciò che sta DAVVERO in coda: chi riprova da solo ne esce (CYRA-317), quindi non compare
      # fra le scelte — sarebbe una voce di menu che porta a una pila vuota. CYRA-790
      def in_queue(gated) = gated.reject { |_, _, state| state == RETRYING_STATE }

      # Il contorno delle sole righe che finiscono in pagina. Precaricato QUI e non con i candidati,
      # che servono anche a comporre i menu: tirarsi dietro quattro associazioni per righe che
      # nessuno mostrerà era il motivo per cui esisteva un tetto stretto. CYRA-790
      def preloaded(gated)
        workflows = gated.map(&:first)
        return gated if workflows.empty?

        ::ActiveRecord::Associations::Preloader.new(
          records: workflows, associations: { ticket: [ { project: :github_repository }, :status ] }
        ).call
        gated
      end

      # I workflow che aspettano una persona sul perimetro chiesto, già risolti in (workflow, fase,
      # stato). Memoizzati per perimetro: senza filtri accesi le tre domande coincidono. CYRA-790
      def gated_agent_workflows(project:, agent:)
        (@gated_agent_workflows ||= {})[[ project&.id, agent&.id ]] ||= resolve_gated_agent_workflows(project:, agent:)
      end

      def resolve_gated_agent_workflows(project:, agent:)
        # Ordine ASC (i più vecchi/urgenti in cima, coerente col merge FIFO): entro il tetto prendiamo
        # i candidati più vecchi, poi gated.first(@limit) sono i più vecchi tra quelli human-gated.
        candidates = candidate_agent_workflows(project:, agent:).order("agents_workflows.updated_at ASC")
                                                                .limit(CANDIDATE_CAP).to_a
        failed = failed_phases_by_workflow(candidates.map(&:id))
        # CYRA-317 — le fasi con un tentativo ancora in volo, precaricate come le respinte: servono a
        # dire, senza una query per riga, se una lavorazione respinta è ferma o sta già riprovando.
        open = open_phases_by_workflow(candidates.map(&:id))
        # Fase e stato si risolvono UNA volta per workflow e viaggiano accanto al suo: la fase decide
        # cosa si può fare (le azioni, il titolo), lo stato dove finisce la riga (coda o elenco
        # separato) e sotto quale conteggio.
        candidates.filter_map do |workflow|
          phase = resolved_phase(workflow, failed[workflow.id])
          next unless HUMAN_GATED_PHASES.include?(phase)
          # Il raffinamento dell'attribuzione gira sull'intero perimetro, non su un suo taglio: una
          # macchina che ha sfiorato molte lavorazioni poi passate ad altri nascondeva l'unica che è
          # davvero sua. CYRA-790
          next if agent && agent_ref_for(workflow, phase)&.id != agent.id

          [ workflow, phase, plan_state(workflow, phase, failed[workflow.id], open[workflow.id]) ]
        end
      end

      # Icona e tono seguono lo STATO, non la fase: una lavorazione che riprova da sola non è un
      # allarme rosso: è lavoro in corso, e col triangolo di quella ferma si leggerebbe come un guasto.
      PLAN_ICONS = { "review_blocked" => "triangle-alert", RETRYING_STATE => "rotate-cw" }.freeze
      PLAN_TONES = { "review_blocked" => :red, RETRYING_STATE => :stone }.freeze

      # Lo stato della riga è di norma la fase, salvo `review_blocked` che si sdoppia: ferma davvero
      # (resta in coda) o già in nuovo tentativo (elenco separato). Il discrimine è lo STESSO che usa
      # Detail#blocked_decisions per offrire il riaccodo, qui letto dalle fasi precaricate: dove il
      # riaccodo non avrebbe nulla da riaprire, la lavorazione sta riprovando da sé.
      def plan_state(workflow, phase, failed_phases, open_phases)
        return phase unless phase == "review_blocked"
        return phase if workflow.blocked_at?

        workflow.stalled_review_phase_from(failed_phases.to_a, open_phases.to_a) ? phase : RETRYING_STATE
      end

      # Workflow candidati: non terminati, in una fase potenzialmente human-gated, dei ticket visibili e
      # col progetto di cui l'account è CTO effettivo. Il perimetro CTO lo compone
      # Agents::Workflows::CtoProjects, che lo dà anche all'elenco delle lavorazioni in volo: due copie
      # davano due numeri diversi sulla stessa pagina. CYRA-665
      def candidate_agent_workflows(project: nil, agent: nil)
        scope = Agents::Workflow
                  .where(ticket_id: visible_ticket_ids, cancelled_at: nil, completed_at: nil)
                  .where(CANDIDATE_AGENT_PLAN_SQL, review_failed: Agents::Attempt.statuses.fetch("review_failed"))
                  .joins(ticket: [ :project, :status ])
                  .where.not(types_ticket_statuses: { category: DONE_CATEGORY })
                  .where(projects: { id: cto_projects.select(:id) })
                  # Il progetto del ticket viaggia con la riga: i menu lo leggono senza precaricare
                  # il ticket, che sarebbe un'associazione per lavorazione mai mostrata.
                  .select("agents_workflows.*, ticketing_tickets.project_id AS gated_project_id")
        # I due filtri entrano QUI, prima di CANDIDATE_CAP: applicati dopo, il tetto veniva riempito
        # dalle lavorazioni degli altri e di quella scelta non restava niente. CYRA-790
        scope = scope.where(projects: { id: project.id }) if project
        scope = scope.where(CANDIDATE_AGENT_HOST_SQL, host: agent.id) if agent
        scope
      end

      # I progetti di cui rispondo, memoizzati: la coda li chiede una volta e ci innesta una subquery.
      def cto_projects
        @cto_projects ||= Agents::Workflows::CtoProjects.scope(
          account: @account, organization: @organization, visible_projects: @visible_projects
        )
      end

      # Richieste di modifica ai secret in attesa (4-eyes): riusa il service esistente, che
      # applica già anti-disclosure (vedo solo i progetti che gestisco o le mie richieste) e
      # l'ordine FIFO. Mostriamo solo le DECIDIBILI (4-eyes esclude le mie).
      def secret_change_source
        pending = Secrets::ChangeRequests::Pending.new(account: @account, projects: @visible_projects)
        decidable = pending.requests.select { |change_request| pending.can_decide?(change_request) }
        project_ids = decidable.map(&:project_id).uniq
        # Un segreto in attesa non porta il nome di una macchina: vale l'uscita delle altre famiglie.
        return EMPTY_SOURCE.merge(project_ids: project_ids) if agent_filter

        decidable = decidable.select { |request| request.project_id == project_filter.id } if project_filter
        items = decidable.first(@limit).map do |change_request|
          item(
            kind: :secret_change, icon: "key", tone: :amber,
            title: t("secret_change.title", name: change_request.name),
            subtitle: "#{change_request.project.name} · #{change_request.environment.label}",
            meta: change_request.requested_by&.name, project: project_ref(change_request.project),
            url: member_vault_attention_path, sort_at: change_request.created_at,
            dom_id: "home_secret_#{change_request.id}", key: "secret_change:#{change_request.id}",
            state: "secret_change",
            bulk_approvable: true
          )
        end
        # Il conteggio è quello delle decidibili del perimetro filtrato: col filtro acceso
        # `decidable_count` parlerebbe di un'altra pila. CYRA-790
        { items: items, totals: { "secret_change" => decidable.size }, project_ids: project_ids, agents: [] }
      end

      # --- "In attesa di risposta" ------------------------------------------------------------

      # Ho già chiesto precisazioni e nessuno ha replicato: la riga resta in pila ma scende in fondo,
      # perché la palla è a qualcun altro. L'evento è scritto DOPO il commento della domanda, quindi un
      # commento successivo è per forza una risposta. È l'ultima parola sullo `state` — `waiting`
      # sovrascrive la famiglia — e ogni spostamento si annota in @reclassified. CYRA-290
      def with_waiting(items)
        asked_at = Ticketing::Event.where(ticket_id: @ticket_by_key&.values&.uniq || [],
                                          action: Decide::ASK_ACTION).group(:ticket_id).maximum(:created_at)
        return items if asked_at.empty?

        replied_at = Ticketing::Comment.where(ticket_id: asked_at.keys).group(:ticket_id).maximum(:created_at)
        items.map do |item|
          ticket_id = @ticket_by_key&.[](item.key)
          asked = ticket_id && asked_at[ticket_id]
          next item if asked.blank? || (replied_at[ticket_id] && replied_at[ticket_id] > asked)
          # CYRA-317 — su ciò che riprova da solo la domanda si annota ma non riclassifica: passare a
          # `waiting` lo rimetterebbe nella coda e nel totale delle decisioni, cioè esattamente dove
          # non deve stare. Il badge "in attesa di risposta" lo mostra comunque l'elenco separato.
          next item.with(waiting_since: asked) if item.state == RETRYING_STATE

          (@reclassified ||= Hash.new(0))[item.state] += 1
          item.with(waiting_since: asked, state: WAITING_STATE)
        end
      end

      def track_ticket(key, ticket_id)
        (@ticket_by_key ||= {})[key] = ticket_id
      end

      # --- Idoneità al blocco -----------------------------------------------------------------

      # Gemello in coda di Home::Approvals::Detail::Card#bulk_approvable?, che resta il gate: qui si
      # decide solo se la riga mostra la casella, con la stessa regola e senza query nuove.
      # `review_blocked` è fuori — lì "accetta" vuol dire "sblocca e riprova", e la sua idoneità reale
      # costerebbe due query per workflow. CYRA-284
      def plan_bulk_approvable?(phase, ticket)
        case phase
        when "awaiting_approval" then true
        when "awaiting_autopilot_approval" then can_manage_ticket?(ticket.project)
        else false
        end
      end

      def can_manage_ticket?(project)
        manage_by_project.fetch(project.id) { manage_by_project[project.id] = resolver.can?("tickets.edit", scope: project) }
      end

      def manage_by_project = @manage_by_project ||= {}

      def resolver
        @resolver ||= Authorization::Resolver.new(account: @account, organization: @organization)
      end

      # --- Helpers ----------------------------------------------------------------------------

      # Una porta sola: da qualunque elenco si guardi una lavorazione, premendo si arriva alla stessa
      # scheda. L'indirizzo si deriva DALLA CHIAVE, qui e non nei quattro costruttori di riga, così una
      # riga nuova che si dimentichi di puntare alla scheda non può esistere. Se la famiglia una scheda
      # non ce l'ha, resta l'indirizzo scelto dal costruttore. CYRA-630
      def item(**attributes)
        card_link = card_url(attributes[:key])
        Feed.item(**(card_link ? attributes.merge(url: card_link) : attributes))
      end

      def card_url(key)
        return if key.blank?

        kind, id = key.split(":", 2)
        return unless Detail::KINDS.include?(kind) && id.present?

        member_home_approvals_item_path(kind: kind, id: id)
      end

      # CYRA-610 — lo stesso avviso del dettaglio, composto qui perché la riga della plancia lo mostra
      # senza aprire niente. Legge solo le colonne del collegamento progetto↔archivio, già precaricate
      # con i candidati: nessuna chiamata a GitHub e nessuna query per riga.
      def plan_freeze_warning(ticket)
        missing = Agents::Plan.decision_for(ticket).missing
        return if missing.nil?

        I18n.t("member.approvals.board.freeze.missing_#{missing}")
      end

      # Stato del ticket per la riga (CYRA-316): label + color dello status, pronti per il badge accanto
      # alla sigla del progetto. Lo `status` è precaricato dalle sorgenti (nessun N+1).
      def ticket_status_badge(ticket) = Feed::Badge.new(label: ticket.status.display_label, color: ticket.status.color)

      # La fase di una riga, letta senza N+1: il lookup su `failed_phases` precalcolate in blocco al
      # posto delle `attempts…exists?`. La catena vive in Agents::Workflows::PhaseResolver e la chiede
      # anche la scheda del ticket, quindi la fase di questa riga e quella della sua scheda sono lo
      # stesso calcolo, non due che si somigliano. CYRA-593, CYRA-796
      def resolved_phase(workflow, failed_phases)
        ::Agents::Workflows::PhaseResolver.phase(workflow, failed_phases)
      end

      def failed_phases_by_workflow(workflow_ids)
        ::Agents::Workflows::PhaseResolver.failed_phases_by_workflow(workflow_ids)
      end

      def open_phases_by_workflow(workflow_ids)
        ::Agents::Workflows::PhaseResolver.open_phases_by_workflow(workflow_ids)
      end

      # Ids dei ticket visibili come subquery (no materializzazione): riusata da clarification e
      # agent_plan per scopare via il workflow → ticket.
      def visible_ticket_ids
        @visible_ticket_ids ||= @visible_tickets.select(:id)
      end

      # Le chiavi i18n restano quelle della home: la pila mostra gli STESSI titoli del feed.
      def t(key, **options)
        I18n.t("member.home.#{key}", **options)
      end
    end
  end
end
