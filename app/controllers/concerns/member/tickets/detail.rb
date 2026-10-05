# frozen_string_literal: true

module Member
  module Tickets
    # CYRA-739 — la pagina di UN ticket e i suoi pannelli: le schede, la cronologia unificata,
    # dipendenze e prerequisiti, l'incidente visto da più progetti, i consigli, la scheda Automazione.
    # È la pagina che carica più materiale di tutte, e ogni pannello ha la sua regola su quando vale
    # la pena chiederlo al database.
    module Detail
      extend ActiveSupport::Concern

      # Schede della show (CYRA-219). "detail" è il default e il fallback di qualunque valore ignoto.
      # "analysis" è l'analisi tecnica (CYRA-259): fuori dal dettaglio, dove faceva muro di testo in
      # coda al corpo non tecnico, e col markdown reso.
      #
      # "report" è il resoconto di lavorazione (CYRA-265). A differenza delle altre **compare solo se il
      # resoconto esiste**: gli altri quattro contenuti o ci sono sempre (dettaglio) o hanno qualcosa da
      # dire anche da vuoti ("nessuna analisi tecnica", "nessun commento"). Un resoconto non c'è finché
      # qualcuno non lo scrive, e una scheda che si apre sul nulla è una scheda in più da provare.
      TABS = %w[detail analysis report automation questions discussion].freeze

      # Tetto dei candidati nel select "Dipendenze" (CYRA-82): `limit` per non riversare migliaia di
      # <option> nel select.
      DEPENDENCY_CANDIDATES_LIMIT = 100

      def show
        # Tre schede sulla STESSA pagina (CYRA-219), scelte da ?tab= e rese server-side: nessun componente
        # JS nuovo, indirizzo condivisibile, Turbo rende lo scambio istantaneo. Whitelist: un tab ignoto
        # torna al dettaglio invece di rendere una scheda vuota.
        @tab = TABS.include?(params[:tab]) ? params[:tab] : "detail"
        # Preload allegati ticket + scenari/DoD + commenti (autore + allegati) + eventi (attori): no N+1.
        @ticket = visible.tickets.with_attached_files
                                         .includes(:scenarios, :conditions, agent_lease: %i[account host])
                                         .find(params[:id])
        return render_history if params[:section] == "history"

        @voted = @ticket.votes.exists?(account_id: Current.account.id)
        @watching = @ticket.subscriptions.exists?(account_id: Current.account.id)
        @watchers_count = @ticket.subscriptions.count
        # Presa in carico in corso (CYRA-295): solo se ANCORA attiva. La riga sopravvive alla scadenza
        # (viene riusata dal titolare successivo), quindi senza il confronto col tempo si mostrerebbe
        # "in lavorazione" per un lavoro finito ore prima. L'autorità sul tempo è PostgreSQL.
        @active_lease = @ticket.agent_lease
        @active_lease = nil unless @active_lease&.active_at?(::Agents::Leases::Clock.current)
        load_discussion if @tab == "discussion"
        @comments_count ||= @ticket.comments.count
        # La sidebar richiede soltanto gli estremi. La cronologia completa vive nel frame
        # del dialog e non viene più materializzata ad ogni apertura/cambio scheda.
        events = @ticket.events.chronological.includes(:actor, :true_actor)
        @created_event = events.find_by(action: "created") || events.first
        @last_event = events.last
        # CYRA-941 — help desk requests that became this ticket or joined it. They hold a visitor's
        # words: only who manages the help desk on the project sees them.
        @helpdesk_requests = can?("helpdesk.manage", scope: @ticket.project) ? @ticket.helpdesk_requests.order(created_at: :desc) : []
        # Collegamenti ticket↔ticket (gate duplicati), letti da entrambe le direzioni.
        @links = Connections::TicketLink.involving(@ticket)
                                        .includes(ticket: [ :project, :status ], related: [ :project, :status ])
                                        .order(:created_at)
        # CYRA-789 — anti-BOLA in lettura, come per le dipendenze: il gate duplicati collega ticket di
        # progetti DIVERSI di proposito (source_ticket_id), quindi l'altro capo può stare dove chi
        # guarda non ha accesso. Il Set permette al partial di oscurare code/title/stato/link di quei
        # capi — resta il fatto che un collegamento esiste, sparisce l'identità. Una sola query (pluck),
        # su entrambe le colonne perché il collegamento si legge da tutti e due i versi.
        @visible_linked_ticket_ids = visible.tickets
                                     .where(id: @links.flat_map { |link| [ link.ticket_id, link.related_id ] }.uniq)
                                     .pluck(:id).to_set
        # Dipendenze/prerequisiti del ticket (CYRA-82): i blocker col loro status, per evidenziare
        # done vs aperto. `@dependency_candidates` popola il select "aggiungi" (vuoto se non gestisce).
        # CYRA-399 — lo stesso identico titolo su progetti diversi: tre ticket con
        # `ConnectionNotEstablished` erano un solo incidente di database, e nessuno lo segnalava.
        # Solo ticket APERTI e solo dentro lo scope visibile, altrimenti la riga rivelerebbe
        # l'esistenza di ticket di progetti che chi guarda non vede.
        @same_incident = same_incident_tickets(@ticket)
        @dependencies = @ticket.dependencies.includes(blocker: [ :project, :status ]).order(:created_at)
        @dependency_candidates = dependency_candidates(@ticket)
        # Anti-BOLA in lettura: un blocker cross-project (ammesso dal model) può stare in un progetto NON
        # visibile a chi guarda A. Il Set dei blocker visibili permette al partial di oscurare code/title/
        # link di quelli fuori scope — resta lo stato (bloccato o no), sparisce l'identità: niente leak
        # intra-org del titolo di un ticket di un progetto non assegnato. Una sola query (pluck).
        @visible_blocker_ids = visible.tickets.where(id: @dependencies.map(&:blocker_id)).pluck(:id).to_set
        # Ticket raccolti sotto questo epic (CYRA-223). Query solo sugli epic: su un ticket qualsiasi
        # la card non viene resa e caricarli sarebbe lavoro buttato.
        @children = @ticket.kind_epic? ? @ticket.children.includes(:project, :status).to_a : []
        # Il pallino sulla scheda Automazione conta le DOMANDE senza risposta, non i giri di chiarimento:
        # un solo giro ne porta fino a tre, e "1" su due domande aperte è semplicemente il numero sbagliato.
        # Una query sola (pluck), su tutte le schede: il conteggio vive nella striscia, sempre visibile.
        # CYRA-782 — le domande aperte sono righe, e contarle è una query sola invece che una somma
        # sulle stringhe di un jsonb. È anche finalmente esatto: comprende le domande poste da una
        # persona, che nel giro di chiarimenti non comparivano.
        @pending_questions = readable_ticket_questions.open.count
        # Il ticket è FERMO solo se aspetta una domanda che qualcuno ha dichiarato bloccante. La riga
        # in testa alla pagina lo dice su OGNI scheda, come le segnalazioni di sicurezza: chi apre il
        # dettaglio deve saperlo, non scoprirlo aprendo la scheda giusta.
        @blocking_questions = readable_ticket_questions.blocking_open.count
        # Resoconto di lavorazione (CYRA-265). `reorder` e non `order`: l'associazione ha già un
        # order(:version) ASCENDENTE e un secondo order ci si ACCODA invece di sostituirlo — la stessa
        # trappola documentata in Ticketing::RecordReport#current, che qui mostrerebbe la stesura numero
        # 1 spacciandola per quella corrente.
        reports = @ticket.reports.reorder(version: :desc)
        @report = @tab == "report" ? reports.first : reports.select(:id, :version).first
        # Lo storico mostra soltanto metadati: i corpi delle versioni precedenti si leggono
        # sulla loro pagina dedicata, mai tutti insieme nella scheda corrente.
        @reports = @tab == "report" ? reports.select(:id, :ticket_id, :version, :source, :author_name).to_a : []
        @previous_report = @tab == "report" && @reports.size > 1 ? reports.offset(1).first : nil
        # `?tab=report` su un ticket che non ha resoconti torna al dettaglio invece di aprire una scheda
        # vuota: stesso trattamento di un tab ignoto.
        #
        # CYRA-627 — a meno che sotto ci sia un verbale di consegna da leggere: senza questa riga, il
        # posto in cui il sistema scrive quello che ha guardato sparirebbe proprio sui ticket che una
        # macchina ha lavorato senza scrivere un resoconto.
        @workflow ||= @ticket.agent_workflow
        @work_report_attempt = work_report_attempt(@workflow)
        @tab = "detail" if @tab == "report" && @report.nil? && @workflow.nil?
        @advice = @tab == "detail" ? advice_lines_of(@ticket) : []
        # CYRA-883 — the last two comments close the detail tab; the whole thread stays in Discussion.
        @recent_comments = @tab == "detail" ? @ticket.comments.includes(:author).reorder(created_at: :desc).limit(2).to_a.reverse : []
        # Su quale scheda vive DAVVERO il racconto del lavoro consegnato (CYRA-557). Nil = da nessuna
        # parte, e il banner della revisione non offre una decisione da prendere alla cieca.
        @review_evidence_tab = review_evidence_tab if @ticket.status.review_gate?
        # Log collegati manualmente (Logs::Link, CYRA-163): backlink di sola lettura, stesso cap delle
        # altre liste di log correlati (related_logs in Member::Monitoring::LogEntriesController).
        @linked_log_entries = @ticket.linked_log_entries.recent.limit(50)
        # CYRA-384 — le segnalazioni di sicurezza trovate dalla lavorazione automatica salgono in cima
        # al ticket, in OGNI scheda: dentro il testo lungo di una scheda secondaria non le vedeva
        # nessuno. Fuori da load_automation_tab apposta — l'avviso non dipende dalla scheda aperta.
        # Nessuna query su un ticket senza lavorazione automatica, che è il caso normale.
        @security_findings = Member::AutomationSecurityFindings.call(ticket: @ticket)
        # CYRA-603 — serve accanto all'elenco, non al posto suo: con l'elenco vuoto la pagina dice
        # «controllato, niente da segnalare», che è un'informazione; senza dichiarazione tace.
        @security_findings_declared = Member::AutomationSecurityFindings.declared?(ticket: @ticket)
        load_automation_tab if @tab == "automation"
        load_questions_tab if @tab == "questions"
      end

      private

      def render_history
        @history = Pagination.call(@ticket.events.reorder(created_at: :desc, id: :desc)
                                           .includes(:actor, :true_actor), page: params[:page], per: params[:per].presence || 50)
        @visible_event_ticket_ids = visible_event_ticket_ids(@history.records)
        render :history, layout: turbo_frame_request? ? false : "member"
      end

      # CYRA-789 — fra i ticket che le righe «collegato» nominano, quelli che chi guarda può davvero
      # vedere: il collegamento attraversa i progetti di proposito, e il codice ne rivela esistenza e
      # progetto. Il riferimento è l'ID scritto nell'evento, MAI il codice — la chiave di progetto è
      # un'etichetta rinominabile e riassegnabile, e un permesso deciso su quella stringa cambierebbe
      # padrone insieme al nome. Gli eventi scritti prima non portano l'id e restano oscurati.
      # Una pluck sola, dagli eventi già in memoria.
      def visible_event_ticket_ids(events)
        ids = events.filter_map { |event| event.data["ticket_id"].presence if event.action == "linked" }
        return Set.new if ids.empty?

        visible.tickets.where(id: ids.uniq).pluck(:id).to_set
      end

      def load_discussion
        comments = @ticket.comments.includes(:author).with_attached_files.to_a
        events = @ticket.events.chronological.includes(:actor, :true_actor).to_a
        @visible_event_ticket_ids = visible_event_ticket_ids(events)
        @timeline = (comments.map { |comment| [ comment.created_at, :comment, comment ] } +
                     events.map { |event| [ event.created_at, :event, event ] })
                    .sort_by { |created_at, _kind, item| [ created_at, item.id ] }
        @comments_count = comments.size
      end

      def dependency_candidates(ticket)
        return Ticketing::Ticket.none unless can?("tickets.edit", scope: ticket.project)

        excluded = [ ticket.id, *ticket.dependencies.pluck(:blocker_id) ]
        visible.tickets
          .where(project_id: ticket.project_id)
          .where.not(id: excluded)
          .includes(:project)
          .order(number: :desc)
          .limit(DEPENDENCY_CANDIDATES_LIMIT)
      end

      # CYRA-623 — i prerequisiti che stanno trattenendo QUESTO ticket in coda, con la domanda della
      # fase pronta: fuori da una fase pronta la coda non lo sta guardando, e dire «trattenuto» sarebbe
      # falso quanto dire «aspetta una macchina libera».
      #
      # I codici escono solo per i prerequisiti che chi guarda può vedere: su un progetto fuori dal suo
      # scope resta il fatto (c'è un prerequisito) senza il codice, che sarebbe una fuga di informazione
      # travestita da messaggio d'aiuto.
      def blocking_prerequisites(ticket, workflow)
        phase = workflow&.ready_execution_phase
        return { codes: [], count: 0 } if phase.blank?

        open_records = Ticketing::DependencyGuard.open_dependencies(
          ticket, mode: Ticketing::DependencyGuard.mode_for(phase)
        )
        return { codes: [], count: 0 } if open_records.empty?

        visible_ids = visible.tickets.where(id: open_records.pluck(:id)).ids.to_set
        { codes: open_records.select { |row| visible_ids.include?(row[:id]) }.pluck(:code), count: open_records.size }
      end

      # CYRA-626 — quello che il sistema non riesce a leggere, e quando ci riprova. Stessa regola
      # dell'elenco delle lavorazioni: mai su una lavorazione che aspetta una persona, mai su una
      # fermata davvero — «riprovo alle 15:40» su un lavoro che aspetta una tua risposta ti fa
      # aspettare per sempre.
      def external_failure(workflow)
        return nil if workflow.nil? || workflow.blocked_at?

        phase = workflow.phase
        return nil if ::Agents::Workflows::PhaseResolver::HUMAN_GATED_PHASES.include?(phase)

        row = if phase == "awaiting_production_proof"
                 workflow.probes.detect { |probe| probe.closed_at.nil? }
        else
                 workflow.delivery_candidates.detect(&:state_unreachable?)
        end
        return nil if row.nil? || row.last_error_code.blank? || row.next_check_at.blank?
        return nil if row.next_check_at <= Time.current

        ::Agents::Workflows::InFlight::RetryHint.new(code: row.last_error_code, at: row.next_check_at)
      end

      # Domande e risposte della sola scheda Domande. Il precarico nomina tutto ciò che la pagina
      # tocca — autore, risposte, autore delle risposte, chi ha ritirato: sotto `strict_loading`
      # un'associazione dimenticata SOLLEVA invece di aggiungere una query per riga.
      # CYRA-883 — the agent's work report lives in the Report tab, so the tab needs it on every page.
      def work_report_attempt(workflow)
        return nil if workflow.nil?

        workflow.attempts.where(phase: "autopilot").order(started_at: :desc, created_at: :desc)
                .detect { |attempt| helpers.automation_work_report(attempt) }
      end

      def load_questions_tab
        @questions = readable_ticket_questions.chronological
                                       .includes(:author, :closed_by, answers: :author).to_a
      end

      # Le domande DI QUESTO TICKET che chi guarda può leggere (CYRA-848): il cliente vede solo le
      # condivise. Nome diverso dal gemello sulle liste (Scoping#readable_questions) apposta: i due
      # concern finiscono nello stesso controller, e due metodi omonimi si sovrascrivono in silenzio. Una porta sola per l'elenco E per i due contatori — un numero che conta anche le
      # riservate racconta al cliente che esiste qualcosa che non può vedere.
      def readable_ticket_questions
        @ticket.questions.readable_by(Current.account, organization: Current.organization)
      end

      # Materiale della sola tab Automazione: tentativi con la macchina che li ha eseguiti, chiarimenti,
      # piano corrente. Caricato QUI e non nella show perché la stragrande maggioranza delle aperture è
      # sul dettaglio, e questi tre giri di query non servono a chi legge la descrizione del ticket.
      def load_automation_tab
        @workflow = @ticket.agent_workflow
        return if @workflow.nil?

        @attempts = @workflow.attempts.includes(:host).order(:started_at, :created_at).to_a
        # CYRA-624 — le prove del rilascio, caricate qui: la vista ne cerca una viva, e senza precarico
        # sarebbe una query in più a ogni apertura della scheda.
        @workflow.probes.load
        # CYRA-626 — anche le righe dei candidati: la scheda cerca quella che il sistema non riesce a
        # leggere, e senza precarico sarebbe una query in più a ogni apertura.
        @workflow.delivery_candidates.load
        @clarifications = @workflow.clarifications.order(:created_at).to_a
        @current_plan = @workflow.plans.last
        # Quante volte la fase su cui si è fermata è stata bocciata: è il numero che il banner mostra, e
        # deve essere LO STESSO che ha fatto scattare il blocco (Agents::Attempts::Deliver). Quindi conta
        # solo dall'ultimo sblocco in poi: le bocciature precedenti sono archivio, e includerle farebbe
        # dire "bocciato 3 volte" dove il tetto è 2. Dagli attempt già caricati, nessuna query in più.
        @blocked_failures = @workflow.stopped_failures(@attempts)
        # Fase che sta riprovando da sola quando la lavorazione è review_blocked ma non ancora ferma
        # (blocked_at nil, budget non esaurito): l'ultima bocciatura tra gli attempt già caricati, senza
        # query in più — non serve altro perché il banner la mostra solo quando blocked_at è assente.
        @retrying_phase = @attempts.reverse_each.find(&:status_review_failed?)&.phase
        # CYRA-384 — le tre righe in testa alla scheda. Dagli stessi attempt già caricati e dalla stessa
        # condizione che decide i pulsanti (CTO effettivo): nessuna query in più, e la sintesi non può
        # dire una cosa mentre i pulsanti ne offrono un'altra.
        cto = @ticket.project.effective_cto
        # CYRA-623 — se la coda sta saltando questo ticket per un prerequisito, la riga «perché si è
        # fermata» lo dice e nomina il codice, invece di promettere una macchina libera che non
        # arriverà. I codici li compone il cancello, così l'elenco e l'ordine sono gli stessi del suo
        # errore; il presenter non fa query.
        blocking = blocking_prerequisites(@ticket, @workflow)
        @automation_summary = Member::AutomationSummary.new(
          workflow: @workflow, attempts: @attempts, decides: cto.present? && cto == Current.account,
          pending_questions: @pending_questions, cto_name: cto&.name,
          blocking_codes: blocking[:codes], blocking_count: blocking[:count],
          retry_hint: external_failure(@workflow)
        )
      end

      # CYRA-557 — dove sta DAVVERO il racconto del lavoro consegnato, nell'ordine in cui lo racconta
      # meglio. Il banner della revisione prometteva «Vedi cosa ha fatto» e portava sempre alla scheda
      # Automazione, che su una lavorazione senza tentativi dichiara di non avere niente: il link
      # apriva il vuoto proprio mentre due pulsanti chiedevano di decidere. Il resoconto è il racconto
      # per esteso; senza, il racconto vero sono i commenti (su PFRA-82 stava tutto lì); l'automazione
      # è l'ultima e SOLO se ha dei tentativi da mostrare — il workflow da solo non racconta niente.
      #
      # Nil = non è stato consegnato niente. Non è un dettaglio di resa: è il gate della decisione.
      #
      # CYRA-389 — vale la stesura che racconta un LAVORO, non la motivazione con cui il lavoro è stato
      # respinto: quella vive nel resoconto come le altre, ma qui aprirebbe il giudizio di chi ha
      # respinto sotto la promessa «Vedi cosa ha fatto». Basta verificarne l'esistenza, senza leggerne i corpi.
      def review_evidence_tab
        return "report" if @ticket.reports.delivered.exists?
        return "discussion" if @comments_count.positive?
        return "automation" if @ticket.agent_workflow&.attempts&.exists?

        nil
      end

      # Ticket con lo STESSO titolo in ALTRI progetti, ancora aperti: un unico guasto visto da più
      # applicazioni. Il confronto è sul titolo esatto, che è quello che rende il caso riconoscibile —
      # un confronto sfumato qui produrrebbe accostamenti che nessuno saprebbe spiegare.
      def same_incident_tickets(ticket)
        return [] if ticket.title.blank?

        visible.tickets.joins(:status)
                               .where.not(project_id: ticket.project_id)
                               .where.not(id: ticket.id)
                               .where(title: ticket.title)
                               .where.not(types_ticket_statuses: { category: Types::TicketStatus.categories[:done] })
                               .includes(:project, :status)
                               .order(:created_at).limit(5).to_a
      end

      # I consigli scritti su questo ticket (CYRA-264). Analisi tecnica E resoconto corrente, perché
      # capita di vedere il lavoro nuovo sia pianificando sia a lavoro finito. Deduplicati: lo stesso
      # consiglio ripetuto nei due campi è una riga sola, non due link che aprono lo stesso ticket.
      def advice_lines_of(ticket)
        sources = [ ticket.technical_analysis, ticket.reports.reorder(version: :desc).limit(1).pick(:body) ]
        sources.compact.flat_map { |text| Ticketing::AdviceLines.call(text: text) }.uniq
      end
    end
  end
end
