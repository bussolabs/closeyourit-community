# frozen_string_literal: true

module Home
  module Approvals
    # Una singola card della pila, risolta dalla sua chiave "famiglia:uuid" e già passata al vaglio
    # dei permessi: se questo account non può decidere, ritorna nil e il controller fa 404 (mai 403 —
    # i record si risolvono sempre dagli scope visibili, anti-BOLA come Member::Home::ActionsController).
    #
    # I predicati qui dentro sono i GEMELLI in Ruby del pre-filtro SQL di Home::Approvals::Queue: la
    # coda deve filtrare in SQL per non materializzare mezza tabella, la singola card no. La parità fra
    # i due è garantita da spec. La FASE non è più fra questi: da CYRA-796 la calcola in un posto solo
    # Agents::Workflows::PhaseResolver, e coda e scheda le chiedono lo stesso calcolo.
    #
    #   Home::Approvals::Detail.call(account:, organization:,
    #     visible_projects:, visible_tickets:, key: "agent_plan:…") → Card | nil
    class Detail < ApplicationService
      include Rails.application.routes.url_helpers

      KINDS = %w[agent_plan review clarification secret_change].freeze

      # Il registro: famiglia → costruttore della sua card. Esplicito perché il nome composto a
      # runtime rendeva questi quattro metodi irraggiungibili cercandoli nel codice, e teneva
      # implicito l'elenco dei casi coperti. Una famiglia nuova è una riga qui. CYRA-801
      CARD_BUILDERS = { "agent_plan" => :agent_plan_card, "review" => :review_card,
                        "clarification" => :clarification_card,
                        "secret_change" => :secret_change_card }.freeze

      # `decisions` = i pulsanti che questo account può davvero premere su QUESTA card, già filtrati
      # per fase e ruolo. La view non decide nulla: rende ciò che trova qui.
      # `attempt` (CYRA-317) = l'ultimo tentativo respinto dalla revisione, quando è lui a spiegare
      # perché la lavorazione è ferma (o cosa sta riprovando). Nil sulle altre fasi.
      # `report` (CYRA-557) = il resoconto corrente del ticket, cioè il racconto di ciò che è stato
      # CONSEGNATO. Nil dove non è quello che si sta decidendo (vedi #delivered_work?).
      # `candidate` (CYRA-616) = il verbale congelato di cosa il sistema ha guardato: quale archivio,
      # quale proposta, quale versione esatta di codice, con che esito dei controlli e a che ora. È il
      # dato su cui si sta dicendo di sì, e prima non compariva da nessuna parte in questa pagina.
      # Nil dove non c'è un verbale — cioè dove non si sta decidendo su una consegna automatica.
      Card = Data.define(:kind, :key, :record, :ticket, :project, :phase, :plan, :attempt, :report,
                         :delivery_attempt,
                         :candidate, :decisions, :url) do
        def can?(decision) = decisions.include?(decision)
        def ticket? = ticket.present?

        # CYRA-591 — l'id del record, senza far ri-spacchettare la chiave a chi costruisce un link.
        # `key` la compone qui sopra: farla disfare fuori significherebbe che il formato
        # "famiglia:uuid" è conosciuto in quattro posti invece che in uno.
        def id = key.split(":", 2).last

        # La lavorazione automatica dietro la card, quando c'è. La sa il posto che ha costruito la
        # card, non la view: lì diventerebbe un `case` sul tipo, e un tipo nuovo farebbe sparire la
        # striscia delle fasi in silenzio invece di sollevare.
        def workflow
          case kind
          when "agent_plan" then record
          when "clarification" then record.workflow
          when "review" then ticket&.agent_workflow
          end
        end

        # Può entrare in una selezione da accettare in blocco (CYRA-284)? Accettare dev'essere un via
        # libera SECCO: nessun testo da scrivere e un solo significato. Le due fasi escluse hanno
        # `approve` eccome, ma non è quel gesto: su `review_blocked` il pulsante dice "Sblocca e
        # riprova". Questo è il GATE: il campo omonimo della coda è solo il suggerimento con cui la UI
        # decide se mostrare la casella.
        NON_BULK_PHASES = %w[review_blocked].freeze

        def bulk_approvable? = can?(:approve) && NON_BULK_PHASES.exclude?(phase)

        # CYRA-557 — le fasi in cui il lavoro è GIÀ STATO CONSEGNATO e la decisione è su quello: lì il
        # resoconto è la cosa che si sta approvando, e la sua assenza va dichiarata (decidere senza è
        # decidere alla cieca, che è esattamente cosa succedeva). Su `awaiting_approval` si decide un
        # PIANO: un resoconto rimasto da una lavorazione precedente racconterebbe un altro lavoro, e
        # chi decide lo leggerebbe come quello di adesso.
        DELIVERED_PHASES = %w[awaiting_autopilot_approval].freeze

        # Il ramo review è per definizione una consegna da giudicare: il ticket è in uno status
        # review-gate, quindi qualcuno (persona o automa) ha dichiarato finito il lavoro.
        def delivered_work? = kind == "review" || DELIVERED_PHASES.include?(phase)
      end

      def initialize(account:, organization:, visible_projects:, visible_tickets:, key:)
        @account = account
        @organization = organization
        @visible_projects = visible_projects
        @visible_tickets = visible_tickets
        @kind, @id = key.to_s.split(":", 2)
      end

      # Famiglia fuori vocabolario → `nil`, come prima (chiave inventata nell'indirizzo = 404, non un
      # errore); il `fetch` parla solo se registro e KINDS divergono, ed è un bug da vedere. CYRA-801
      def call
        return nil unless KINDS.include?(@kind) && @id.present?

        send(CARD_BUILDERS.fetch(@kind))
      end

      private

      # Piano/lavoro dell'automa in attesa del CTO effettivo. La fase decide cosa si può fare: a
      # review bloccata NON esiste ancora un piano, quindi approvarlo o farlo rifare fallirebbe
      # `stale` (vedi Agents::Workflows::Unblock) — lì si sblocca, o si annulla del tutto.
      def agent_plan_card
        workflow = Agents::Workflow.where(ticket_id: @visible_tickets.select(:id), cancelled_at: nil, completed_at: nil)
                                   .includes(ticket: [ :project, :status ]).find_by(id: @id)
        return nil if workflow.blank?

        phase = workflow.phase
        return nil unless Queue::HUMAN_GATED_PHASES.include?(phase)

        ticket = workflow.ticket
        return nil if ticket.status.category_done? # CYRA-316: ticket concluso, decisione non più utile
        return nil unless ticket.project.effective_cto == @account

        card(kind: "agent_plan", record: workflow, ticket: ticket, phase: phase,
             plan: workflow.plans.reorder(version: :desc).first,
             attempt: (last_review_failure(workflow) if phase == "review_blocked"),
             report: (ticket.current_work_report if DELIVERED_PHASES.include?(phase)),
             delivery_attempt: (latest_delivery_attempt(workflow) if DELIVERED_PHASES.include?(phase)),
             decisions: plan_decisions(workflow, phase), url: member_ticket_path(ticket, tab: "automation"))
      end

      # Il tentativo che la revisione ha respinto per ultimo: è ciò che spiega perché la lavorazione è
      # ferma, o cosa sta riprovando (CYRA-317). Prima il pannello mostrava una frase e mezzo schermo
      # bianco, e chi doveva decidere se chiuderla lo faceva alla cieca. Una query sola, sulla singola
      # card aperta — la coda non passa mai di qui.
      def last_review_failure(workflow)
        workflow.attempts.status_review_failed.includes(:host).order(:started_at).last
      end

      # awaiting_approval → decido il piano. awaiting_autopilot_approval → è a tutti gli effetti una
      # review del lavoro fatto, e passa dai service di review (che delegano ad ApproveAutopilot):
      # quindi serve anche tickets.edit. review_blocked → vedi #blocked_decisions.
      def plan_decisions(workflow, phase)
        decisions = case phase
        when "awaiting_approval" then %i[approve reject ask]
        when "awaiting_autopilot_approval"
                      can_manage?(workflow.ticket.project) ? %i[approve reject ask] : %i[ask]
        else blocked_decisions(workflow)
        end
        askable(workflow, reassessable(workflow, decisions))
      end

      # CYRA-675 — «Rivaluta» si offre dove la domanda ha ancora senso, e a dirlo è il dominio
      # (Agents::Workflow#reassessable?), non un elenco di fasi ricopiato qui: la stessa regola la
      # rilegge sotto lock Workflows::Reassess, e due copie divergono al primo stato nuovo. Passa da
      # qui anche `awaiting_autopilot_approval`, e infatti non la ottiene: lì il codice è già scritto.
      def reassessable(workflow, decisions)
        workflow.reassessable? ? decisions + %i[reassess] : decisions
      end

      # `review_blocked` dice che UNA review è fallita, non che la lavorazione sia per forza ferma: se la
      # fase bocciata è il planner riparte da sola e Agents::Workflows::Unblock non farebbe nulla — offrire
      # "sblocca e riprova" sarebbe un pulsante che finge, e lì resta solo la domanda. Ferma lo è quando il
      # budget dei tentativi è esaurito (`blocked_at`) OPPURE quando la fase bocciata era stata claimata e
      # la coda non la ripropone più (CYRA-267): sotto il tetto il blocco non scatta, ma la lavorazione è
      # morta uguale. Chiudere è di admin/owner (gate di Agents::Workflows::Cancel).
      def blocked_decisions(workflow)
        decisions = []
        decisions << :approve if workflow.blocked_at? || workflow.stalled_review_phase
        decisions << :reject if can_cancel_workflow?
        decisions << :ask
      end

      # Ticket in uno status review-gate di cui sono il revisore designato.
      def review_card
        ticket = @visible_tickets.includes(:project, :status).find_by(id: @id)
        return nil if ticket.blank? || !ticket.status.review_gate? || ticket.reviewer_id != @account.id
        return nil if ticket.status.category_done? # CYRA-316: status finale (config non-default), decisione superata

        # CYRA-557 — il resoconto è il racconto di ciò che è stato consegnato: senza, la card mostrava
        # descrizione, analisi tecnica e criteri di accettazione (tutte cose scritte PRIMA che il
        # lavoro cominciasse) e poi offriva Approva e Respingi. Una query sola, sulla card aperta.
        # CYRA-389 — l'ultima stesura in assoluto può essere la motivazione con cui questo lavoro è
        # stato respinto il giro prima: mostrarla qui vorrebbe dire farla leggere come il lavoro.
        card(kind: "review", record: ticket, ticket: ticket, report: ticket.current_work_report,
             delivery_attempt: latest_delivery_attempt(ticket.agent_workflow),
             decisions: review_decisions(ticket), url: member_ticket_path(ticket))
      end

      # Essere il revisore designato basta per LEGGERE — la card è ferma su di me e devo poterla aprire
      # per girarla a chi decide. Approvare o respingere richiede invece tickets.edit sul progetto
      # (stesso gate dei pulsanti sulla show): senza, restano il testo e la domanda. Ritornare nil
      # significherebbe 404 su una riga che la pila mostra — il revisore senza permesso ce l'ha in coda.
      def review_decisions(ticket)
        askable(ticket.agent_workflow, can_manage?(ticket.project) ? %i[approve reject ask] : %i[ask])
      end

      # Se l'automa ha una domanda aperta su questo ticket, la palla è già mia su UN'ALTRA card della
      # pila. Un commento scritto da qui verrebbe agganciato come risposta a quella domanda
      # (Ticketing::AddComment#capture_clarification_response), chiudendola con un testo che non le
      # risponde e rimettendo il ticket in coda al triage. Si risponde lì, non si chiede qui.
      def askable(workflow, decisions)
        return decisions if workflow.blank? || !workflow.clarifications.where(answered_at: nil).exists?

        decisions - %i[ask]
      end

      # Domanda dell'automa ancora senza risposta: qui il verso è opposto (chiede lui), l'unica azione
      # è rispondere.
      #
      # CYRA-665 — il perimetro è quello della coda: la domanda è del REVISORE del ticket. Prima
      # bastava vedere il ticket, e la card restava raggiungibile per indirizzo anche a chi la coda
      # non l'aveva mai proposto — che è esattamente la scorciatoia che questa classe esiste per non
      # avere. Rispondere resta possibile a chiunque veda il lavoro, ma dalla scheda del ticket, dove
      # si legge tutto il contesto: qui si passa solo per la pila delle decisioni.
      def clarification_card
        clarification = Agents::Clarification.where(answered_at: nil)
                                             .joins(workflow: :ticket)
                                             .where(agents_workflows: { ticket_id: @visible_tickets.select(:id) })
                                             .where(ticketing_tickets: { reviewer_id: @account.id })
                                             .includes(workflow: { ticket: [ :project, :status ] }).find_by(id: @id)
        return nil if clarification.blank?

        ticket = clarification.workflow.ticket
        return nil if ticket.status.category_done? # CYRA-316: ticket concluso, la domanda non sblocca più nulla
        card(kind: "clarification", record: clarification, ticket: ticket, decisions: %i[reply],
             url: member_ticket_path(ticket, tab: "automation"))
      end

      # Richiesta di modifica a un secret: la decidibilità (permesso + 4-eyes + anti-disclosure) la
      # sa già Secrets::ChangeRequests::Pending — riusata, non reimplementata.
      def secret_change_card
        pending = Secrets::ChangeRequests::Pending.new(account: @account, projects: @visible_projects)
        change_request = pending.requests.find { |request| request.id == @id }
        return nil if change_request.blank? || !pending.can_decide?(change_request)

        card(kind: "secret_change", record: change_request, project: change_request.project,
             decisions: %i[approve reject], url: member_vault_attention_path)
      end

      def card(kind:, record:, decisions:, url:, ticket: nil, project: nil, phase: nil, plan: nil,
               attempt: nil, report: nil, delivery_attempt: nil)
        composed = Card.new(kind: kind, key: "#{kind}:#{@id}", record: record, ticket: ticket,
                            project: project || ticket&.project, phase: phase, plan: plan,
                            attempt: attempt, report: report, delivery_attempt: delivery_attempt, candidate: nil,
                            decisions: decisions, url: url)
        composed.with(candidate: frozen_candidate(composed))
      end

      # CYRA-616 — il verbale si mostra dove si decide su una CONSEGNA, e solo se esiste davvero.
      #
      # La regola è «esiste il verbale congelato», non un elenco di fasi cablato: un elenco andrebbe
      # tenuto allineato a mano ogni volta che le fasi cambiano, e il giorno che si dimentica la riga
      # sparisce in silenzio proprio dove serve. Sul piano da approvare resta nil, e la riga non
      # compare nemmeno vuota: lì il codice non è ancora stato scritto, e un riquadro vuoto farebbe
      # credere che qualcosa sia già stato controllato.
      def frozen_candidate(card)
        return nil unless card.delivered_work?

        card.workflow&.review_candidate
      end

      def latest_delivery_attempt(workflow)
        return if workflow.nil?

        workflow.attempts.where(phase: "autopilot", status: :approved)
                .where("result ? 'work_report'").order(:finished_at, :created_at).last
      end

      def can_manage?(project)
        resolver.can?("tickets.edit", scope: project)
      end

      # Annullare l'automazione è riservato ad admin/owner (Agents::Workflows::Cancel): senza il
      # ruolo il pulsante non deve nemmeno comparire, altrimenti si offre una decisione che fallisce.
      def can_cancel_workflow?
        @organization.memberships.find_by(account: @account)&.role.in?(%w[admin owner])
      end

      def resolver
        @resolver ||= Authorization::Resolver.new(account: @account, organization: @organization)
      end
    end
  end
end
