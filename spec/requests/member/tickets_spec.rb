# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }

  # I tre attori nascono con la loro membership solo quando un esempio li nomina (CYRA-551). Prima
  # li creava tutti e tre un `before` comune: la gran parte degli esempi ne usa uno, e pagava
  # comunque tre account, tre membership e due assegnazioni di progetto — un terzo del tempo di
  # questo file, che è il più lento della suite. Un esempio che ha bisogno anche degli altri li
  # nomina, come già fanno quelli che contano i membri o compilano il filtro assegnatario.
  #
  # admin = il manager: nel nuovo regime serve un attore con tutti i permessi → owner (unscoped).
  let(:admin) { account_with_membership(:owner) }
  # Scoping: member/customer vedono e aprono ticket solo su progetti assegnati.
  let(:member) { account_with_membership(:member, on_project: true) }
  let(:customer) { account_with_membership(:customer, on_project: true) }

  def account_with_membership(role, on_project: false)
    create(:account).tap do |account|
      create(:membership, account: account, organization: org, role: role)
      create(:project_membership, account: account, project: project) if on_project
    end
  end

  # Ticket di massa — paginazione della lista e blocchi della board (CYRA-551).
  #
  # Lasciato a sé, il factory dà a ogni ticket un reporter suo (account + membership) e una priorità
  # sua: tre insert in più per riga, su liste di trenta righe di cui si verifica solo quante ne
  # compaiono e in che ordine. Qui reporter e priorità sono condivisi; chi verifica proprio quelli
  # (il preload del reporter, il filtro per priorità) continua a passarseli espliciti o a creare i
  # ticket a mano, e questi helper non c'entrano.
  let(:bulk_reporter) { account_with_membership(:member) }

  def bulk_ticket(**attributes)
    create(:ticket, **bulk_ticket_defaults, **attributes)
  end

  def bulk_tickets(count, *traits, **attributes)
    create_list(:ticket, count, *traits, **bulk_ticket_defaults, **attributes)
  end

  def bulk_ticket_defaults
    { organization: org, project: project, priority: priority, reporter: bulk_reporter }
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def valid_params(extra = {})
    {
      project_id: project.id, title: "Checkout broken",
      scenarios_attributes: [ { step_given: "Safari 17", step_when: "click Checkout", step_then: "nothing", step_expected: "proceeds" } ],
      status_id: status.id, priority_id: priority.id
    }.merge(extra)
  end

  describe "GET list (tabella)" do
    it "non autenticato → redirect login" do
      get list_member_tickets_path
      expect(response).to redirect_to(login_path)
    end

    # M1 — a short date on one line ("12 Mar"), the year only when it is not this year.
    it "writes the created date short and on one line" do
      bulk_ticket(created_at: Time.zone.local(Date.current.year, 3, 12, 9))
      sign_in(admin)

      get list_member_tickets_path

      cell = Capybara.string(response.body).find("[data-test='ticket-created-cell']")
      expect(cell.text.strip).to eq(I18n.l(Date.new(Date.current.year, 3, 12), format: :day_month))
      expect(cell[:class]).to include("whitespace-nowrap")
    end

    it "membro → 200" do
      sign_in(member)
      get list_member_tickets_path
      expect(response).to have_http_status(:ok)
    end

    it "customer → 200 (vede i ticket)" do
      sign_in(customer)
      get list_member_tickets_path
      expect(response).to have_http_status(:ok)
    end

    it "mostra la graffetta solo per i ticket con allegati" do
      sign_in(member)
      attached = create(:ticket, organization: org, project: project)
      attached.files.attach(fixture_file_upload("notes.txt", "text/plain"))
      plain = create(:ticket, organization: org, project: project)

      get list_member_tickets_path

      expect(response.body).to include("ticket-attachments-indicator-#{attached.id}")
      expect(response.body).not_to include("ticket-attachments-indicator-#{plain.id}")
    end

    it "mostra l'icona robot su ogni riga, col colore del gate agenti" do
      sign_in(member)
      workable = create(:ticket, organization: org, project: project, agent_eligibility: :allowed)
      blocked = create(:ticket, organization: org, project: project, agent_eligibility: :blocked)
      pending_gate = create(:ticket, organization: org, project: project, agent_eligibility: :pending)

      get list_member_tickets_path

      expect(response.body).to include("ticket-agent-indicator-#{workable.id}")
      expect(response.body).to include("ticket-agent-indicator-#{blocked.id}")
      expect(response.body).to include("ticket-agent-indicator-#{pending_gate.id}")
      expect(response.body).to include("text-emerald-600", "text-gray-300", "text-amber-500")
      expect(Nokogiri::HTML(response.body).at_css("svg[data-icon='bot']")).to be_present
    end

    it "filtra per status (param array)" do
      sign_in(member)
      other = create(:ticket_status, organization: org)
      t1 = create(:ticket, organization: org, project: project, status: status)
      t2 = create(:ticket, organization: org, project: project, status: other)
      get list_member_tickets_path, params: { status_id: [ status.id ] }
      expect(response.body).to include(t1.code)
      expect(response.body).not_to include(t2.code)
    end

    it "filtra per priority" do
      sign_in(member)
      other = create(:ticket_priority, organization: org)
      t1 = create(:ticket, organization: org, project: project, priority: priority)
      t2 = create(:ticket, organization: org, project: project, priority: other)
      get list_member_tickets_path, params: { priority_id: [ priority.id ] }
      expect(response.body).to include(t1.code)
      expect(response.body).not_to include(t2.code)
    end

    it "filtra per assignee" do
      sign_in(member)
      t1 = create(:ticket, organization: org, project: project, assignee: member)
      t2 = create(:ticket, organization: org, project: project)
      get list_member_tickets_path, params: { assignee_id: [ member.id ] }
      expect(response.body).to include(t1.code)
      expect(response.body).not_to include(t2.code)
    end

    it "filtra per project" do
      sign_in(member)
      other_project = create(:project, organization: org)
      create(:project_membership, account: member, project: other_project)
      t1 = create(:ticket, organization: org, project: project)
      t2 = create(:ticket, organization: org, project: other_project)
      get list_member_tickets_path, params: { project_id: [ project.id ] }
      expect(response.body).to include(t1.code)
      expect(response.body).not_to include(t2.code)
    end

    it "filtra per kind (solo story)" do
      sign_in(member)
      feature = create(:ticket, :story, organization: org, project: project, title: "Dark mode")
      bug = create(:ticket, organization: org, project: project, title: "Crash login")
      get list_member_tickets_path, params: { kind: [ "story" ] }
      expect(response.body).to include(feature.code)
      expect(response.body).not_to include(bug.code)
    end

    it "cerca per titolo" do
      sign_in(member)
      match = create(:ticket, organization: org, project: project, title: "Unique checkout glitch")
      other = create(:ticket, organization: org, project: project, title: "Something else")
      get list_member_tickets_path, params: { q: "checkout" }
      expect(response.body).to include(match.code)
      expect(response.body).not_to include(other.code)
    end

    describe "filtro gate agenti" do
      it "passa solo i ticket dell'eleggibilità scelta" do
        sign_in(member)
        allowed = create(:ticket, organization: org, project: project, agent_eligibility: :allowed)
        blocked = create(:ticket, organization: org, project: project, agent_eligibility: :blocked)
        pending_ticket = create(:ticket, organization: org, project: project)

        get list_member_tickets_path, params: { agent_eligibility: [ "allowed" ] }

        aggregate_failures do
          expect(response.body).to include(allowed.code)
          expect(response.body).not_to include(blocked.code)
          expect(response.body).not_to include(pending_ticket.code)
        end
      end

      it "accetta più valori insieme" do
        sign_in(member)
        allowed = create(:ticket, organization: org, project: project, agent_eligibility: :allowed)
        blocked = create(:ticket, organization: org, project: project, agent_eligibility: :blocked)
        pending_ticket = create(:ticket, organization: org, project: project)

        get list_member_tickets_path, params: { agent_eligibility: %w[allowed blocked] }

        aggregate_failures do
          expect(response.body).to include(allowed.code, blocked.code)
          expect(response.body).not_to include(pending_ticket.code)
        end
      end

      it "il chip in cima conta i ticket ancora da valutare" do
        sign_in(member)
        # La factory legge `ticket.agent_workflow` a ogni create: due create consecutivi identici
        # sembrano un N+1 a Prosopite, ma è il SETUP, non la lista.
        allow_n_plus_one { create_list(:ticket, 2, organization: org, project: project) }
        create(:ticket, organization: org, project: project, agent_eligibility: :allowed)

        get list_member_tickets_path

        expect(response.body).to include("tickets-count-pending-eligibility")
        expect(response.body).to include(">2<")
      end
    end

    describe "ricerca per codice" do
      it "il ticket esatto viene per primo, poi chi lo cita" do
        sign_in(member)
        target = create(:ticket, organization: org, project: project, title: "Preferenza space")
        citing = create(:ticket, organization: org, project: project,
                                 title: "Dipende da #{target.code}", description: "vedi #{target.code}")
        unrelated = create(:ticket, organization: org, project: project, title: "Nulla a che vedere")

        get list_member_tickets_path, params: { q: target.code, semantic: "1" }

        aggregate_failures do
          # Sui PATH, non sui codici: il codice cercato viene rimandato a video nella barra di
          # ricerca, quindi `body.index(target.code)` troverebbe quell'eco e l'ordine risulterebbe
          # giusto comunque. I link esistono solo nelle righe.
          expect(response.body).to include(member_ticket_path(target))
          expect(response.body).to include(member_ticket_path(citing))
          expect(response.body).not_to include(member_ticket_path(unrelated))
          # L'esatto precede chi lo cita: è il punto della funzione.
          expect(response.body.index(member_ticket_path(target)))
            .to be < response.body.index(member_ticket_path(citing))
        end
      end

      it "è insensibile a maiuscole e spazi" do
        sign_in(member)
        target = create(:ticket, organization: org, project: project)

        get list_member_tickets_path, params: { q: "  #{target.code.downcase} ", semantic: "1" }

        expect(response.body).to include(target.code)
      end

      it "un codice di un'altra organizzazione non compare (anti-BOLA)" do
        other_org = create(:organization)
        other_project = create(:project, organization: other_org, key: "ZZZZ")
        foreign = create(:ticket, organization: other_org, project: other_project)
        sign_in(member)

        get list_member_tickets_path, params: { q: foreign.code, semantic: "1" }

        # Non basta cercare il codice come stringa: la barra di ricerca lo rimanda a video come
        # valore del campo. Ciò che conta è che non esista una RIGA che porti a quel ticket.
        expect(response.body).not_to include(member_ticket_path(foreign))
      end

      it "un codice inesistente non svuota la lista per effetto collaterale" do
        sign_in(member)
        mentions = create(:ticket, organization: org, project: project,
                                   title: "Qualcosa su #{project.key}-9999")

        # Il codice è ben formato ma non risolve → si prosegue con la ricerca normale (qui ILIKE,
        # perché senza `semantic` il ramo è quello testuale).
        get list_member_tickets_path, params: { q: "#{project.key}-9999" }

        # Sul PATH: il codice cercato compare comunque nel campo di ricerca, quindi asserirlo come
        # stringa passerebbe anche con la lista vuota — cioè proprio il caso che questo test esclude.
        expect(response.body).to include(member_ticket_path(mentions))
      end

      it "trova anche chi cita il codice nell'analisi tecnica" do
        sign_in(member)
        target = create(:ticket, organization: org, project: project)
        # In produzione è il posto più frequente: 160 ticket citano un codice SOLO qui, contro 104
        # fra titolo e descrizione. E questo ramo ferma la ricerca semantica, quindi senza cercarlo
        # anche nell'analisi quei ticket non emergerebbero in nessun modo.
        in_analysis = create(:ticket, organization: org, project: project, title: "Senza riferimenti",
                                      technical_analysis: "Dipende da #{target.code} per il claim")

        get list_member_tickets_path, params: { q: target.code, semantic: "1" }

        expect(response.body).to include(member_ticket_path(in_analysis))
      end

      it "i citanti hanno un ordine proprio, indipendente dall'ordinamento della colonna" do
        sign_in(member)
        target = create(:ticket, organization: org, project: project)
        # I due ordinamenti sono DELIBERATAMENTE opposti: per titolo verrebbe primo il più vecchio,
        # per data il più recente. Solo così il test distingue le due strade.
        older = create(:ticket, organization: org, project: project,
                                title: "Alfa cita #{target.code}", created_at: 3.days.ago)
        newer = create(:ticket, organization: org, project: project,
                                title: "Zulu cita #{target.code}", created_at: 1.hour.ago)

        # L'ordine dei citanti deve restare il suo — più recenti prima — perché è quello che rende
        # deterministico anche il taglio a TOP_K, qualunque colonna l'utente scelga per la lista.
        get list_member_tickets_path, params: { q: target.code, semantic: "1", sort: "title" }

        expect(response.body.index(member_ticket_path(newer)))
          .to be < response.body.index(member_ticket_path(older))
      end

      it "il numero non è un prefisso: cercando CYRA-14 non escono i CYRA-141" do
        sign_in(member)
        target = create(:ticket, organization: org, project: project)
        longer = create(:ticket, organization: org, project: project,
                                 title: "Riguarda #{project.key}-#{target.number}0")

        get list_member_tickets_path, params: { q: target.code, semantic: "1" }

        aggregate_failures do
          expect(response.body).to include(member_ticket_path(target))
          expect(response.body).not_to include(member_ticket_path(longer))
        end
      end
    end

    describe "ordinamento (?sort=)" do
      let!(:zebra) { create(:ticket, organization: org, project: project, title: "Zebra crash") }
      let!(:apple) { create(:ticket, organization: org, project: project, title: "apple glitch") }

      def positions(body, *codes)
        codes.map { |code| body.index(code) }
      end

      it "sort=title → ascendente case-insensitive" do
        sign_in(member)
        get list_member_tickets_path, params: { sort: "title" }
        a, z = positions(response.body, apple.code, zebra.code)
        expect(a).to be < z
      end

      it "sort=-title → discendente" do
        sign_in(member)
        get list_member_tickets_path, params: { sort: "-title" }
        a, z = positions(response.body, apple.code, zebra.code)
        expect(z).to be < a
      end

      it "chiave fuori whitelist → 200 con ordine di default (created_at desc)" do
        sign_in(member)
        get list_member_tickets_path, params: { sort: "evil;drop" }
        expect(response).to have_http_status(:ok)
        a, z = positions(response.body, apple.code, zebra.code)
        expect(a).to be < z # apple creato dopo → primo col default newest-first
      end

      it "sort=assignee (join nullable): i non assegnati restano in fondo" do
        sign_in(member)
        zebra.update!(assignee: admin)
        get list_member_tickets_path, params: { sort: "assignee" }
        z, a = positions(response.body, zebra.code, apple.code)
        expect(z).to be < a
      end

      it "convive coi filtri: sort applicato al sottoinsieme filtrato" do
        sign_in(member)
        other_status = create(:ticket_status, organization: org)
        zebra.update!(status: status)
        apple.update!(status: status)
        excluded = create(:ticket, organization: org, project: project, status: other_status, title: "AAA first")
        get list_member_tickets_path, params: { sort: "title", status_id: [ status.id ] }
        expect(response.body).not_to include(excluded.code)
        a, z = positions(response.body, apple.code, zebra.code)
        expect(a).to be < z
      end

      it "i link di paginazione preservano il sort" do
        sign_in(member)
        allow_n_plus_one { 15.times { |i| bulk_ticket(title: "Bulk #{i}") } }
        get list_member_tickets_path, params: { sort: "-title" }
        expect(response.body).to include("sort=-title&amp;page=2").or include("page=2&amp;sort=-title")
      end

      it "semantic=1: la pertinenza vince sul sort colonna" do
        sign_in(member)
        allow(Ticketing::SemanticSearch).to receive(:call)
          .and_return(Result.ok([ zebra.id, apple.id ]))
        get list_member_tickets_path, params: { q: "crash", semantic: "1", sort: "title" }
        z, a = positions(response.body, zebra.code, apple.code)
        expect(z).to be < a # ordine di pertinenza (zebra prima), non alfabetico
      end
    end

    it "pagina: la seconda pagina è diversa dalla prima" do
      sign_in(member)
      # Fixture bulk: ogni ticket crea un reporter+membership → una tenant-check per record (query di
      # setup identiche), non un N+1 di produzione.
      allow_n_plus_one { 30.times { |i| bulk_ticket(status: status, title: "Bug #{i}") } }
      get list_member_tickets_path, params: { page: 1 }
      page1 = response.body
      get list_member_tickets_path, params: { page: 2 }
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to eq(page1)
    end

    it "i link di riga escono dal turbo-frame (data-turbo-frame=_top): la show è full-page, non dentro tickets-results" do
      sign_in(member)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      get list_member_tickets_path
      links = Nokogiri::HTML(response.body).css(%(a[href="#{member_ticket_path(ticket)}"]))
      expect(links).not_to be_empty
      expect(links.map { |a| a["data-turbo-frame"] }).to all(eq("_top"))
    end
  end

  describe "GET index (board di default)" do
    it "filtra per gate agenti anche sulla board" do
      sign_in(member)
      allowed = create(:ticket, organization: org, project: project, status: status, agent_eligibility: :allowed)
      blocked = create(:ticket, organization: org, project: project, status: status, agent_eligibility: :blocked)

      get member_tickets_path, params: { agent_eligibility: [ "allowed" ] }

      aggregate_failures do
        expect(response.body).to include(allowed.code)
        expect(response.body).not_to include(blocked.code)
        # Il filtro dev'essere anche OFFERTO, non solo funzionante via URL.
        expect(response.body).to include("filter-agent-eligibility")
      end
    end

    it "cerca per codice anche dalla board" do
      sign_in(member)
      target = create(:ticket, organization: org, project: project, status: status)
      other = create(:ticket, organization: org, project: project, status: status, title: "Altro")

      get member_tickets_path, params: { q: target.code, semantic: "1" }

      aggregate_failures do
        # Sul PATH: `target.code` viene ri-emesso nel campo di ricerca, quindi asserirlo come
        # stringa passerebbe anche con la board vuota.
        expect(response.body).to include(member_ticket_path(target))
        expect(response.body).not_to include(member_ticket_path(other))
      end
    end

    it "mostra la graffetta sulle card dei ticket con allegati" do
      sign_in(member)
      ticket = create(:ticket, organization: org, project: project, status: status, with_agent_workflow: true)
      ticket.files.attach(fixture_file_upload("notes.txt", "text/plain"))

      get member_tickets_path

      expect(response.body).to include("ticket-attachments-indicator-#{ticket.id}")
    end

    it "mostra l'icona robot sulla card, accesa solo dove l'agente può lavorare" do
      sign_in(member)
      workable = create(:ticket, organization: org, project: project, status: status,
                                 agent_eligibility: :allowed)
      blocked = create(:ticket, organization: org, project: project, status: status,
                                agent_eligibility: :blocked)

      get member_tickets_path

      expect(response.body).to include("ticket-agent-indicator-#{workable.id}")
      expect(response.body).to include("ticket-agent-indicator-#{blocked.id}")
      expect(response.body).to include("text-emerald-600", "text-gray-300")
    end

    it "membro → 200, le card compaiono nella board" do
      sign_in(member)
      ticket = create(:ticket, organization: org, project: project, status: status, with_agent_workflow: true)
      get member_tickets_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ticket.code)
    end

    it "shows the filter bar as the toolbar of the white board panel (K9)" do
      sign_in(member)
      get member_tickets_path
      expect(response).to have_http_status(:ok)
      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='board-panel'].bg-white [data-test='board-toolbar']")
      expect(html).to have_no_css("[data-test='board-toolbar'].sticky")
    end

    it "conteggia i ticket in status 'in corso' (chip board_in_progress)" do
      sign_in(member)
      wip = create(:ticket_status, organization: org, category: :in_progress, code: "wip", label: "In corso")
      create(:ticket, organization: org, project: project, status: wip)
      get member_tickets_path
      expect(response).to have_http_status(:ok)
    end

    it "customer → 200 (vede la board)" do
      sign_in(customer)
      get member_tickets_path
      expect(response).to have_http_status(:ok)
    end

    it "non autenticato → redirect login" do
      get member_tickets_path
      expect(response).to redirect_to(login_path)
    end

    context "filtri (stesse chiavi param della list, senza status che è l'asse colonne)" do
      it "filtra per project" do
        sign_in(member)
        other_project = create(:project, organization: org)
        create(:project_membership, account: member, project: other_project)
        mine = create(:ticket, organization: org, project: project, status: status)
        elsewhere = create(:ticket, organization: org, project: other_project, status: status)
        get member_tickets_path, params: { project_id: [ project.id ] }
        expect(response.body).to include(mine.code)
        expect(response.body).not_to include(elsewhere.code)
      end

      it "filtra per kind (solo story)" do
        sign_in(member)
        feature = create(:ticket, :story, organization: org, project: project, status: status, title: "Dark mode")
        bug = create(:ticket, organization: org, project: project, status: status, title: "Crash login")
        get member_tickets_path, params: { kind: [ "story" ] }
        expect(response.body).to include(feature.code)
        expect(response.body).not_to include(bug.code)
      end

      it "filtra per priority" do
        sign_in(member)
        other = create(:ticket_priority, organization: org)
        t1 = create(:ticket, organization: org, project: project, status: status, priority: priority)
        t2 = create(:ticket, organization: org, project: project, status: status, priority: other)
        get member_tickets_path, params: { priority_id: [ priority.id ] }
        expect(response.body).to include(t1.code)
        expect(response.body).not_to include(t2.code)
      end

      it "filtra per assignee" do
        sign_in(member)
        t1 = create(:ticket, organization: org, project: project, status: status, assignee: member)
        t2 = create(:ticket, organization: org, project: project, status: status)
        get member_tickets_path, params: { assignee_id: [ member.id ] }
        expect(response.body).to include(t1.code)
        expect(response.body).not_to include(t2.code)
      end

      it "cerca per titolo (q)" do
        sign_in(member)
        match = create(:ticket, organization: org, project: project, status: status, title: "Unique checkout glitch")
        other = create(:ticket, organization: org, project: project, status: status, title: "Something else")
        get member_tickets_path, params: { q: "checkout" }
        expect(response.body).to include(match.code)
        expect(response.body).not_to include(other.code)
      end

      it "accetta project_id multi-valore (param array)" do
        sign_in(member)
        p2 = create(:project, organization: org)
        create(:project_membership, account: member, project: p2)
        t1 = create(:ticket, organization: org, project: project, status: status)
        t2 = create(:ticket, organization: org, project: p2, status: status)
        get member_tickets_path, params: { project_id: [ project.id, p2.id ] }
        expect(response.body).to include(t1.code)
        expect(response.body).to include(t2.code)
      end

      it "filtro senza match → 200, board vuota (nessun crash)" do
        sign_in(member)
        create(:ticket, organization: org, project: project, status: status)
        empty_project = create(:project, organization: org)
        create(:project_membership, account: member, project: empty_project)
        get member_tickets_path, params: { project_id: [ empty_project.id ] }
        expect(response).to have_http_status(:ok)
      end
    end

    context "finestra recente sulle colonne concluse (CYRA-390)" do
      let!(:done_status) { create(:ticket_status, :done, organization: org, code: "resolved", position: 5) }

      it "mostra solo i conclusi di recente e dichiara la finestra in intestazione" do
        sign_in(member)
        recent = create(:ticket, organization: org, project: project, status: done_status)
        old = create(:ticket, organization: org, project: project, status: done_status)
        recent.update_column(:closed_at, 1.day.ago)
        old.update_column(:closed_at, 10.days.ago)

        get member_tickets_path

        aggregate_failures do
          expect(response.body).to include(recent.code)
          expect(response.body).not_to include(old.code)
          expect(response.body).to include("board-window-resolved")
        end
      end

      it "il conteggio di colonna resta il totale reale, non le sole card mostrate" do
        sign_in(member)
        recent = create(:ticket, organization: org, project: project, status: done_status)
        recent.update_column(:closed_at, 1.day.ago)
        old = create(:ticket, organization: org, project: project, status: done_status)
        old.update_column(:closed_at, 30.days.ago)

        get member_tickets_path

        html = Capybara.string(response.body)
        aggregate_failures do
          # 2 conclusi in totale, 1 solo dentro la finestra: il chip dice il vero (2).
          expect(html.find("[data-test='board-count-resolved']").text).to eq("2")
          # E lo storico oltre la finestra resta raggiungibile dalla vista lista.
          expect(response.body).to include("board-view-all-resolved")
        end
      end

      it "la colonna conclusa vuota nella finestra non dice «niente» sotto un totale pieno" do
        sign_in(member)
        old = create(:ticket, organization: org, project: project, status: done_status)
        old.update_column(:closed_at, 30.days.ago)

        get member_tickets_path

        empty = Capybara.string(response.body).find("[data-test='board-column-resolved'] [data-test='board-column-empty']", visible: :all)
        expect(empty.text(:all)).to include(I18n.t("member.tickets.board.empty_recent", days: 7))
      end
    end

    context "paginazione per colonna (CYRA-390)" do
      it "carica un primo blocco e offre «mostra altre» oltre la soglia" do
        sign_in(member)
        # Fixture bulk: il factory valida il tenant e crea un agent_workflow per ticket — query
        # per-record del setup, non un N+1 di produzione (i ticket nascono uno alla volta).
        allow_n_plus_one do
          bulk_tickets(Ticketing::Constants::BOARD_COLUMN_PAGE + 2, status: status)
        end

        get member_tickets_path

        html = Capybara.string(response.body)
        shown = html.all("#board_column_#{status.id} [data-ticket-board-target='card']").size
        aggregate_failures do
          expect(shown).to eq(Ticketing::Constants::BOARD_COLUMN_PAGE)
          expect(response.body).to include("board-more-#{status.code}")
        end
      end

      it "niente «mostra altre» quando la colonna sta in un solo blocco" do
        sign_in(member)
        create(:ticket, organization: org, project: project, status: status)
        get member_tickets_path
        expect(response.body).not_to include("board-more-#{status.code}")
      end
    end

    context "colonne ridotte, preferenza personale (CYRA-390)" do
      it "rende ridotta la colonna che l'utente ha collassato" do
        sign_in(member)
        member.update!(board_collapsed_statuses: [ status.code ])
        create(:ticket, organization: org, project: project, status: status)

        get member_tickets_path

        html = Capybara.string(response.body)
        expect(html.find("[data-test='board-column-#{status.code}']")["data-collapsed"]).to eq("true")
      end

      it "colonna aperta di default (nessuna preferenza)" do
        sign_in(member)
        create(:ticket, organization: org, project: project, status: status)
        get member_tickets_path
        html = Capybara.string(response.body)
        expect(html.find("[data-test='board-column-#{status.code}']")["data-collapsed"]).to eq("false")
      end

      it "riduce di default le colonne concluse (stanno tutte su uno schermo da 13\")" do
        sign_in(member)
        done_status = create(:ticket_status, :done, organization: org, code: "resolved", position: 5)
        create(:ticket, organization: org, project: project, status: status)

        get member_tickets_path

        html = Capybara.string(response.body)
        aggregate_failures do
          # La conclusa parte ridotta, la colonna di lavoro vivo resta aperta.
          expect(html.find("[data-test='board-column-resolved']")["data-collapsed"]).to eq("true")
          expect(html.find("[data-test='board-column-#{status.code}']")["data-collapsed"]).to eq("false")
        end
      end

      # CYRA-691 — chi arriva per «cosa è stato consegnato» (un cliente esterno, mai configurato)
      # trovava ripiegate esattamente le colonne che rispondono alla sua domanda.
      it "una conclusa con lavoro recente parte APERTA; ripiegata resta solo la conclusa vuota" do
        sign_in(member)
        resolved = create(:ticket_status, :done, organization: org, code: "resolved", position: 5)
        create(:ticket_status, :done, organization: org, code: "closed", position: 6)
        create(:ticket, organization: org, project: project, status: resolved, closed_at: 2.days.ago)

        # La board fa di proposito una query per colonna (LIMIT per blocco, CYRA-390): con due
        # colonne concluse le due query si somigliano e prosopite le scambierebbe per N+1.
        allow_n_plus_one { get member_tickets_path }

        html = Capybara.string(response.body)
        aggregate_failures do
          expect(html.find("[data-test='board-column-resolved']")["data-collapsed"]).to eq("false")
          expect(html.find("[data-test='board-column-closed']")["data-collapsed"]).to eq("true")
        end
      end
    end
  end

  describe "GET column (mostra altre — CYRA-390)" do
    it "appende il blocco successivo di card via Turbo Stream" do
      sign_in(member)
      # Fixture bulk nel setup (vedi sopra): fuori dalla finestra N+1 di produzione.
      allow_n_plus_one do
        bulk_tickets(Ticketing::Constants::BOARD_COLUMN_PAGE + 2, status: status)
      end

      get column_member_tickets_path(status_id: status.id, page: 2),
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include("board_column_#{status.id}")
        expect(response.body).to include("board-card-")
      end
    end

    it "senza Turbo ripiega sulla vista lista filtrata per stato" do
      sign_in(member)
      get column_member_tickets_path(status_id: status.id, page: 2)
      expect(response).to redirect_to(list_member_tickets_path(status_id: [ status.id ]))
    end

    it "status di un'altra organizzazione → 404 (anti-BOLA)" do
      sign_in(member)
      foreign = create(:ticket_status, organization: create(:organization))
      get column_member_tickets_path(status_id: foreign.id, page: 2)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET show" do
    it "membro → 200" do
      sign_in(member)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      get member_ticket_path(ticket)
      expect(response).to have_http_status(:ok)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      sign_in(admin)
      foreign = create(:ticket, organization: create(:organization))
      get member_ticket_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    # CYRA-24: il conteggio dei watcher è già nel pulsante watch → il badge presence
    # "sta guardando" (member/viewers/badge) è ridondante e va tolto dalla show del ticket.
    it "non mostra il badge presence viewers 'sta guardando' (ridondante col pulsante watch)" do
      sign_in(member)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      get member_ticket_path(ticket)
      expect(response.body).not_to include('data-test="viewers-badge"')
      expect(response.body).not_to include('data-controller="viewers"')
    end

    it "conserva il conteggio dei watcher nel pulsante watch" do
      sign_in(member)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      get member_ticket_path(ticket)
      expect(response.body).to include('data-test="member-ticket-watchers-count"')
    end

    it "shows the status in Details without the sentence that explained it" do
      sign_in(admin)
      open_status = create(:ticket_status, organization: org, code: "open")
      ticket = create(:ticket, organization: org, project: project, status: open_status, with_agent_workflow: true)
      get member_ticket_path(ticket)
      expect(response.body).to include('data-test="ticket-status"')
      expect(response.body).not_to include('data-test="ticket-status-hint"')
    end
  end

  # CYRA-399 — tre ticket con lo stesso identico titolo su tre progetti erano un solo incidente di
  # database, e nessuno lo segnalava.
  # CYRA-403 — l'icona che dice se un ticket è lavorabile in automatico affidava l'informazione a
  # una sfumatura di colore su quattordici pixel: senza nome, senza legenda, invisibile a un lettore
  # di schermo.
  describe "GET list (indicatore del gate agenti)" do
    it "l'icona porta il valore per esteso ed è annunciabile" do
      ticket = create(:ticket, organization: org, project:, status:, priority:,
                               agent_eligibility: :allowed, with_agent_workflow: true)
      sign_in(admin)

      get list_member_tickets_path

      icon = Nokogiri::HTML(response.body).at_css(%([data-test="ticket-agent-indicator-#{ticket.id}"]))
      expect(icon["role"]).to eq("img")
      expect(icon["aria-label"]).to eq(I18n.t("member.tickets.agent_eligibility.allowed"))
      expect(icon["title"]).to eq(icon["aria-label"])
      expect(icon.at_css("svg")["aria-hidden"]).to eq("true")
    end

    it "i tre casi si distinguono per forma, non solo per colore" do
      # Tre ticket nel SETUP: le query per-record del seed non sono N+1 della pagina.
      allow_n_plus_one do
        %i[allowed pending blocked].each do |value|
          create(:ticket, organization: org, project:, status:, priority:,
                          agent_eligibility: value)
        end
      end
      sign_in(admin)

      get list_member_tickets_path

      icons = Nokogiri::HTML(response.body).css('[data-test^="ticket-agent-indicator-"] svg')
      glyphs = icons.map { |icon| icon["data-icon"] }.uniq
      expect(glyphs.size).to be >= 3
    end

    it "l'elenco porta la legenda dei tre casi" do
      create(:ticket, organization: org, project:, status:, priority:)
      sign_in(admin)

      get list_member_tickets_path

      expect(response.body).to include('data-test="tickets-agent-legend"')
      %w[allowed pending blocked].each do |value|
        expect(response.body).to include(%(data-test="tickets-agent-legend-#{value}"))
        expect(response.body).to include(I18n.t("member.tickets.agent_eligibility.#{value}"))
      end
    end
  end

  describe "GET show (stesso incidente su più progetti)" do
    it "segnala i ticket aperti con lo stesso titolo su altri progetti" do
      altro = create(:project, organization: org, name: "Secondo progetto")
      titolo = "Il database non risponde"
      mio = create(:ticket, organization: org, project:, status:, priority:, title: titolo)
      gemello = create(:ticket, organization: org, project: altro, status:, priority:, title: titolo)
      sign_in(admin)

      get member_ticket_path(mio)

      expect(response.body).to include('data-test="ticket-same-incident"')
      expect(response.body).to include(gemello.code, ERB::Util.html_escape(altro.name))
    end

    it "non segnala i ticket dello stesso progetto né quelli chiusi" do
      altro = create(:project, organization: org, name: "Terzo progetto")
      chiuso_status = create(:ticket_status, :done, organization: org)
      titolo = "Una richiesta ha superato il tempo massimo"
      mio = create(:ticket, organization: org, project:, status:, priority:, title: titolo)
      stesso_progetto = create(:ticket, organization: org, project:, status:, priority:, title: titolo)
      chiuso = create(:ticket, organization: org, project: altro, status: chiuso_status, priority:, title: titolo)
      sign_in(admin)

      get member_ticket_path(mio)

      # Il codice di un ticket dello stesso progetto compare altrove nella pagina (suggerimenti,
      # collegamenti): qui conta che NON ci sia la segnalazione dell'incidente unico.
      expect(stesso_progetto).to be_present
      expect(chiuso).to be_present
      expect(response.body).not_to include('data-test="ticket-same-incident"')
    end

    it "non rivela ticket di progetti che non vedo" do
      nascosto_progetto = create(:project, organization: org, name: "Progetto riservato")
      titolo = "Il database non risponde"
      mio = create(:ticket, organization: org, project:, status:, priority:, title: titolo)
      nascosto = create(:ticket, organization: org, project: nascosto_progetto, status:, priority:,
                                 title: titolo)
      sign_in(member)

      get member_ticket_path(mio)

      expect(response.body).not_to include(nascosto.code)
      expect(response.body).not_to include("Progetto riservato")
    end
  end

  describe "GET new" do
    it "admin → 200" do
      sign_in(admin)
      get new_member_ticket_path
      expect(response).to have_http_status(:ok)
    end

    # CYRA-398 — il modulo chiedeva uno stato che ha una sola risposta sensata, partiva dalla
    # priorità più bassa, elencava gli obiettivi di tutti i progetti e non diceva che dopo il
    # salvataggio parte una valutazione automatica.
    it "non chiede lo stato: lo mostra e lo manda nascosto" do
      Types::InstallDefaults.call(organization: org)
      sign_in(admin)

      get new_member_ticket_path

      html = Nokogiri::HTML(response.body)
      expect(html.at_css('[data-test="ticket-status-initial"]')).to be_present
      expect(html.at_css('[data-test="ticket-status"]')).to be_nil
      hidden = html.at_css('input[name="status_id"]')
      expect(hidden["type"]).to eq("hidden")
      expect(hidden["value"]).to eq(org.ticket_statuses.active.ordered.find(&:category_open?).id)
    end

    it "propone una priorità che non è la più bassa" do
      Types::InstallDefaults.call(organization: org)
      sign_in(admin)

      get new_member_ticket_path

      selected = Nokogiri::HTML(response.body).at_css('select#priority_id option[selected]')
      expect(selected["value"]).to eq(org.ticket_priorities.find_by(code: "medium").id)
    end

    it "gli obiettivi omonimi di progetti diversi si distinguono" do
      altro = create(:project, organization: org, name: "Secondo progetto")
      create(:milestone, project:, label: "S0 Fondamenta")
      create(:milestone, project: altro, label: "S0 Fondamenta")
      sign_in(admin)

      get new_member_ticket_path

      options = Nokogiri::HTML(response.body).css('select#milestone_id option[value!=""]')
      expect(options.map { |option| option["data-description"] }).to include(project.name, altro.name)
      expect(options.map { |option| option["title"] }).to include(project.name, altro.name)
    end

    it "avvisa che dopo il salvataggio parte la valutazione automatica" do
      sign_in(admin)

      get new_member_ticket_path

      expect(response.body).to include('data-test="ticket-triage-notice"')
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.tickets.form.triage_notice")))
    end

    # Il nome vecchio compare ancora una volta in pagina — nella voce di changelog che racconta il
    # cambio — quindi l'asserzione è sul PULSANTE, che è ciò che il ticket chiede.
    it "il pulsante di scrittura assistita dice cosa fa" do
      sign_in(admin)

      get new_member_ticket_path

      button = Nokogiri::HTML(response.body).at_css('[data-test="ticket-compose-open"]')
      expect(button.text.strip).to eq(I18n.t("member.tickets.compose.button"))
      expect(button.text).not_to include("AI Buddy")
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.tickets.compose.explain")))
    end

    it "modificando un ticket lo stato torna una scelta" do
      ticket = create(:ticket, organization: org, project:, status:, priority:, with_agent_workflow: true)
      sign_in(admin)

      get edit_member_ticket_path(ticket)

      expect(response.body).to include('data-test="ticket-status"')
      expect(response.body).not_to include('data-test="ticket-status-initial"')
    end

    it "draws a scenario as one block: numbered title, four clause rows growing with their text" do
      ticket = create(:ticket, organization: org, project:, status:, priority:)
      create(:ticketing_scenario, ticket:)
      sign_in(admin)
      get edit_member_ticket_path(ticket)
      row = Nokogiri::HTML(response.body).at_css('[data-test="ticket-scenario-row"]')

      expect(row.at_css('[data-test="ticket-scenario-number"]')).to be_present
      expect(row.css('[data-test^="help-scenario"]')).to be_empty
      clauses = row.css('[data-test="ticket-scenario-clause"]')
      expect(clauses.size).to eq(4)
      expect(clauses.map { it.at_css("textarea")["class"] }).to all(include("[field-sizing:content]"))
      expect(clauses.last["class"]).to include("bg-indigo-50")
      expect(clauses.first(3).map { it["class"] }.join).not_to include("bg-indigo-50")
    end

    it "starts with no scenario: the person adds one when they want it" do
      sign_in(admin)
      get new_member_ticket_path
      list = Nokogiri::HTML(response.body).at_css('[data-test="ticket-scenarios"] [data-nested-fields-target="container"]')

      expect(list.css('[data-test="ticket-scenario-row"]')).to be_empty
    end

    it "membro → 200 (tutti possono aprire ticket)" do
      sign_in(member)
      get new_member_ticket_path
      expect(response).to have_http_status(:ok)
    end

    # Il bersaglio viaggia come valore proprio, accanto alla quota (CYRA-263): la quota resta il
    # default degli altri campi, qui non deve piu' decidere niente. Se sparisse l'attributo, lo
    # Stimulus ricadrebbe sulla quota e il contatore tornerebbe ad avvisare a 1.200 su 1.500 —
    # cioe' quando il testo e' gia' scritto.
    it "l'analisi tecnica dichiara il bersaglio, non solo il tetto" do
      sign_in(member)
      get new_member_ticket_path
      field = Nokogiri::HTML(response.body).at_css('[data-controller="char-counter"]:has([data-test="ticket-technical-analysis"])')

      expect(field["data-char-counter-max-value"]).to eq(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS.to_s)
      expect(field["data-char-counter-warn-at-value"]).to eq(Ticketing::Constants::TECHNICAL_ANALYSIS_TARGET_CHARS.to_s)
    end

    # Le etichette sono la parte che si dimentica: ricordarsele a memoria non funziona, e un campo
    # vuoto non suggerisce niente. Il placeholder e' la guida nel punto in cui si scrive.
    it "l'analisi tecnica mostra le etichette come esempio" do
      sign_in(member)
      get new_member_ticket_path
      placeholder = Nokogiri::HTML(response.body).at_css('[data-test="ticket-technical-analysis"]')["placeholder"]

      expect(placeholder).to include("Approccio:")
      expect(placeholder).to include("Rischi:")
    end

    it "customer → 200" do
      sign_in(customer)
      get new_member_ticket_path
      expect(response).to have_http_status(:ok)
    end

    it "con ?project_id di un progetto dell'org → progetto bloccato (no select)" do
      sign_in(member)
      get new_member_ticket_path(project_id: project.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="ticket-project-locked"')
      expect(response.body).to include('name="locked_project"')
      expect(response.body).not_to include('data-test="ticket-project"')
    end

    it "con ?project_id di un'altra org → form normale (nessun blocco, anti-leak)" do
      sign_in(member)
      # Name esplicito e univoco: il factory usa `Faker::App.name` (pool finito, NON univoco) che può
      # collidere col nome di un progetto visibile del member → l'asserzione su `name` darebbe un falso
      # positivo (il name appare per via del progetto legittimo, non del leak). La key è univoca (sequence).
      foreign = create(:project, name: "Cross-Org Foreign Project", organization: create(:organization))
      get new_member_ticket_path(project_id: foreign.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="ticket-project"')
      expect(response.body).not_to include('data-test="ticket-project-locked"')
      expect(response.body).not_to include(ERB::Util.html_escape(foreign.name))
      expect(response.body).not_to include(foreign.key)
      expect(response.body).not_to include("value=\"#{foreign.id}\"")
    end

    # CYRA-1043 — same organization, but outside the member's scope: nothing of it may show up.
    it "with ?project_id of a project of the same org the member cannot see → normal form, no leak" do
      sign_in(member)
      hidden = create(:project, name: "Hidden Same-Org Project", organization: org)
      get new_member_ticket_path(project_id: hidden.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="ticket-project"')
      expect(response.body).not_to include('data-test="ticket-project-locked"')
      expect(response.body).not_to include(ERB::Util.html_escape(hidden.name))
      expect(response.body).not_to include(hidden.key)
      expect(response.body).not_to include("value=\"#{hidden.id}\"")
    end

    context "prefill piattaforma" do
      it "progetto con una sola piattaforma → la preseleziona (a prescindere dal profilo)" do
        platform = create(:platform, organization: org)
        project.project_platforms.create!(platform: platform)
        sign_in(admin)
        get new_member_ticket_path(project_id: project.id)
        option = Nokogiri::HTML(response.body)
                 .at_css(%(select[data-test="ticket-platforms"] option[value="#{platform.id}"]))
        expect(option).to be_present
        expect(option["selected"]).to be_present
      end

      # CYRA-1043 — the single platform of a project the member cannot see must not be pre-checked.
      it "hidden project of the same org with one platform → no preselection" do
        hidden = create(:project, organization: org)
        platform = create(:platform, organization: org)
        hidden.project_platforms.create!(platform: platform)
        sign_in(member)
        get new_member_ticket_path(project_id: hidden.id)
        option = Nokogiri::HTML(response.body)
                 .at_css(%(select[data-test="ticket-platforms"] option[value="#{platform.id}"]))
        expect(option["selected"]).to be_nil
      end

      it "progetto con più piattaforme e nessun platform_code → nessuna preselezione" do
        project.project_platforms.create!(platform: create(:platform, organization: org))
        project.project_platforms.create!(platform: create(:platform, organization: org))
        sign_in(admin)
        get new_member_ticket_path(project_id: project.id)
        selected = Nokogiri::HTML(response.body)
                   .css(%(select[data-test="ticket-platforms"] option[selected]))
        expect(selected).to be_empty
      end

      it "form aperto → espone la mappa progetto→piattaforme per il prefill JS" do
        platform = create(:platform, organization: org)
        project.project_platforms.create!(platform: platform)
        sign_in(admin)
        get new_member_ticket_path
        expect(response.body).to include("data-ticket-platforms-map-value")
        expect(response.body).to include(platform.id)
      end

      it "mappa progetto→piattaforme: le piattaforme inattive vengono escluse (ramo else)" do
        active = create(:platform, organization: org, active: true)
        inactive = create(:platform, organization: org, active: false)
        project.project_platforms.create!(platform: active)
        project.project_platforms.create!(platform: inactive)
        sign_in(admin)
        get new_member_ticket_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(active.id)
        expect(response.body).not_to include(inactive.id)
      end

      it "prefill da platform_codes ristretto al progetto (project_id presente, più piattaforme)" do
        ios = create(:platform, organization: org, code: "ios")
        web = create(:platform, organization: org, code: "web")
        project.project_platforms.create!(platform: ios)
        project.project_platforms.create!(platform: web)
        admin.update!(platform_codes: [ "ios" ])
        sign_in(admin)
        get new_member_ticket_path(project_id: project.id)
        option = Nokogiri::HTML(response.body)
                 .at_css(%(select[data-test="ticket-platforms"] option[value="#{ios.id}"]))
        expect(option["selected"]).to be_present
      end

      it "prefill da platform_codes senza progetto selezionato (nessuna restrizione per progetto)" do
        ios = create(:platform, organization: org, code: "ios")
        admin.update!(platform_codes: [ "ios" ])
        sign_in(admin)
        get new_member_ticket_path
        option = Nokogiri::HTML(response.body)
                 .at_css(%(select[data-test="ticket-platforms"] option[value="#{ios.id}"]))
        expect(option["selected"]).to be_present
      end
    end
  end

  describe "POST create" do
    it "admin crea un ticket (reporter = account)" do
      sign_in(admin)
      expect { post member_tickets_path, params: valid_params }.to change(Ticketing::Ticket, :count).by(1)
      ticket = Ticketing::Ticket.last
      expect(ticket.reporter).to eq(admin)
      expect(ticket.scenarios.first.step_given).to eq("Safari 17")
      expect(response).to redirect_to(member_ticket_path(ticket))
    end

    it "crea scenari multipli, condizioni DoD e analisi tecnica" do
      sign_in(admin)
      post member_tickets_path, params: valid_params(
        scenarios_attributes: [
          { title: "Happy", step_given: "loggato", step_when: "compra", step_then: "ok" },
          { title: "Errore", step_when: "compra", step_then: "500" }
        ],
        conditions_attributes: [ { text: "arriva la mail" } ],
        technical_analysis: "N+1 su Orders#create",
      )
      ticket = Ticketing::Ticket.last
      expect(ticket.scenarios.map(&:title)).to eq([ "Happy", "Errore" ])
      expect(ticket.conditions.map(&:text)).to eq([ "arriva la mail" ])
      expect(ticket.technical_analysis).to eq("N+1 su Orders#create")
    end

    it "uno scenario con un solo step basta come corpo → redirect" do
      sign_in(admin)
      post member_tickets_path, params: valid_params(scenarios_attributes: [ { step_given: "solo contesto" } ])
      expect(response).to redirect_to(member_ticket_path(Ticketing::Ticket.last))
    end

    it "da solo testo semplice (descrizione, nessuno scenario) → crea e redirect" do
      sign_in(admin)
      expect do
        post member_tickets_path, params: valid_params(description: "Il checkout su Safari non parte",
          scenarios_attributes: [])
      end.to change(Ticketing::Ticket, :count).by(1)
      ticket = Ticketing::Ticket.last
      expect(ticket).to be_kind_bug
      expect(ticket.description).to eq("Il checkout su Safari non parte")
      expect(response).to redirect_to(member_ticket_path(ticket))
    end

    it "senza alcun corpo (né descrizione né scenari) → 422" do
      sign_in(admin)
      post member_tickets_path, params: valid_params(description: "", scenarios_attributes: [])
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "descrizione oltre il limite → 422, il ticket non nasce" do
      sign_in(admin)

      expect do
        post member_tickets_path,
             params: valid_params(description: "x" * (Ticketing::Constants::DESCRIPTION_MAX_CHARS + 1))
      end.not_to change(Ticketing::Ticket, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "analisi tecnica oltre il limite → 422 con l'errore stampato sotto al campo" do
      sign_in(admin)

      expect do
        post member_tickets_path,
             params: valid_params(technical_analysis: "y" * (Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS + 1))
      end.not_to change(Ticketing::Ticket, :count)
      expect(response).to have_http_status(:unprocessable_content)
      error = Nokogiri::HTML(response.body).at_css('[data-test="ticket-technical-analysis-error"]')
      expect(error.text).to include(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS.to_s)
    end

    it "crea una feature: titolo + description, niente scenari → redirect" do
      sign_in(admin)
      expect do
        post member_tickets_path, params: valid_params(kind: "story", description: "serve dark mode",
          scenarios_attributes: [])
      end.to change(Ticketing::Ticket, :count).by(1)
      ticket = Ticketing::Ticket.last
      expect(ticket).to be_kind_story
      expect(ticket.description).to eq("serve dark mode")
      expect(response).to redirect_to(member_ticket_path(ticket))
    end

    it "feature senza corpo (né description né scenari) → 422" do
      sign_in(admin)
      post member_tickets_path, params: valid_params(kind: "story", description: "", scenarios_attributes: [])
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "membro apre un ticket (reporter = membro)" do
      sign_in(member)
      expect { post member_tickets_path, params: valid_params }.to change(Ticketing::Ticket, :count).by(1)
      expect(Ticketing::Ticket.last.reporter).to eq(member)
    end

    it "customer apre un ticket (reporter = customer)" do
      sign_in(customer)
      expect { post member_tickets_path, params: valid_params }.to change(Ticketing::Ticket, :count).by(1)
      expect(Ticketing::Ticket.last.reporter).to eq(customer)
    end

    it "project inesistente → 422 (project_not_found)" do
      sign_in(admin)
      post member_tickets_path, params: valid_params(project_id: SecureRandom.uuid)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "con assignee membro → ticket assegnato" do
      sign_in(admin)
      post member_tickets_path, params: valid_params(assignee_id: member.id)
      expect(Ticketing::Ticket.last.assignee).to eq(member)
    end

    it "da un progetto bloccato (locked_project) → ticket collegato a quel progetto" do
      sign_in(member)
      expect do
        post member_tickets_path, params: valid_params(locked_project: "1")
      end.to change(Ticketing::Ticket, :count).by(1)
      expect(Ticketing::Ticket.last.project).to eq(project)
      expect(response).to redirect_to(member_ticket_path(Ticketing::Ticket.last))
    end

    it "con due_at (scadenza) → salva la data e ora" do
      sign_in(admin)
      post member_tickets_path, params: valid_params(due_at: "2026-08-01T17:00")
      expect(Ticketing::Ticket.last.due_at.strftime("%Y-%m-%d %H:%M")).to eq("2026-08-01 17:00")
    end

    it "create fallito da progetto bloccato → ri-renderizza il form mantenendo il lock (422)" do
      sign_in(admin)
      post member_tickets_path, params: valid_params(locked_project: "1", description: "", scenarios_attributes: [])
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET edit" do
    it "admin → 200" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      get edit_member_ticket_path(ticket)
      expect(response).to have_http_status(:ok)
    end

    it "membro → redirect (gestione = admin/owner)" do
      sign_in(member)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      get edit_member_ticket_path(ticket)
      expect(response).to redirect_to(root_path)
    end

    it "customer → redirect" do
      sign_in(customer)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      get edit_member_ticket_path(ticket)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "PATCH update" do
    it "admin aggiorna titolo e clausole" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: status, priority: priority, with_agent_workflow: true)
      patch member_ticket_path(ticket), params: valid_params(title: "New title")
      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(ticket.reload.title).to eq("New title")
    end

    it "admin imposta la due_at (scadenza)" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: status, priority: priority, with_agent_workflow: true)
      patch member_ticket_path(ticket), params: valid_params(due_at: "2026-09-15T09:30")
      expect(ticket.reload.due_at.strftime("%Y-%m-%d %H:%M")).to eq("2026-09-15 09:30")
    end

    it "titolo vuoto → 422" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: status, priority: priority, title: "Old", with_agent_workflow: true)
      patch member_ticket_path(ticket), params: valid_params(title: "")
      expect(response).to have_http_status(:unprocessable_content)
      expect(ticket.reload.title).to eq("Old")
    end

    it "assegna un membro in update" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: status, priority: priority, with_agent_workflow: true)
      patch member_ticket_path(ticket), params: valid_params(assignee_id: member.id)
      expect(ticket.reload.assignee).to eq(member)
    end

    # CYRA-788 — stato rifiutato dal cancello dei prerequisiti: anche il titolo cambiato nello stesso
    # modulo NON va salvato, e in cronologia non resta nulla.
    it "stato rifiutato per un prerequisito aperto → 422 e il titolo resta com'era" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: status, priority: priority, title: "Old", with_agent_workflow: true)
      blocker = create(:ticket, organization: org, project: project, status: status)
      create(:ticket_dependency, ticket: ticket, blocker: blocker)
      in_progress = create(:ticket_status, :in_progress, organization: org)

      patch member_ticket_path(ticket), params: valid_params(title: "New title", status_id: in_progress.id)

      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to eq(I18n.t("member.tickets.errors.blocked_by_dependencies", count: 1))
      expect(ticket.reload.title).to eq("Old")
      expect(ticket.status).to eq(status)
      expect(Ticketing::Event.where(ticket: ticket)).not_to exist
    end
  end

  describe "DELETE destroy" do
    it "admin elimina" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      expect { delete member_ticket_path(ticket), params: { confirm: "1" } }.to change(Ticketing::Ticket, :count).by(-1)
      expect(response).to redirect_to(member_tickets_path)
    end

    it "membro → redirect, ticket resta" do
      sign_in(member)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      expect { delete member_ticket_path(ticket) }.not_to change(Ticketing::Ticket, :count)
    end
  end

  describe "PATCH status" do
    it "admin cambia lo status" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: status, with_agent_workflow: true)
      other = create(:ticket_status, organization: org)
      patch status_member_ticket_path(ticket), params: { status_id: other.id }
      expect(ticket.reload.status).to eq(other)
    end

    it "membro → redirect (gate)" do
      sign_in(member)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      patch status_member_ticket_path(ticket), params: { status_id: status.id }
      expect(response).to redirect_to(root_path)
    end

    it "customer → redirect (non gestisce)" do
      sign_in(customer)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      patch status_member_ticket_path(ticket), params: { status_id: status.id }
      expect(response).to redirect_to(root_path)
    end

    it "status inesistente → risponde con lo status dell'errore (il board ripristina la card), status invariato" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: status, with_agent_workflow: true)
      patch status_member_ticket_path(ticket), params: { status_id: SecureRandom.uuid }
      # Endpoint colpito solo dal drag della board (fetch): su errore lo status dell'errore fa
      # ricaricare e ripristinare la card, invece del redirect che il fetch seguirebbe come 200.
      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to be_present
      expect(ticket.reload.status).to eq(status)
    end

    # CYRA-163 — dal dettaglio (dropdown status) la stessa route arriva con `inline=1`: su errore
    # segue il redirect_back+alert come assignee/reviewer, invece della risposta head-only
    # pensata per il fetch della board.
    it "inline=1 e prerequisito aperto → redirect con alert (dependency guard), status invariato" do
      sign_in(admin)
      in_progress = create(:ticket_status, :in_progress, organization: org)
      blocker = create(:ticket, organization: org, project: project, status: status)
      ticket = create(:ticket, organization: org, project: project, status: status, with_agent_workflow: true)
      create(:ticket_dependency, ticket: ticket, blocker: blocker)

      patch status_member_ticket_path(ticket), params: { status_id: in_progress.id, inline: 1 }

      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(flash[:alert]).to be_present
      expect(ticket.reload.status).to eq(status)
    end

    it "inline=1 e status valido → redirect con notice, come le altre azioni inline" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, status: status, with_agent_workflow: true)
      other = create(:ticket_status, organization: org)

      patch status_member_ticket_path(ticket), params: { status_id: other.id, inline: 1 }

      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(flash[:notice]).to be_present
      expect(ticket.reload.status).to eq(other)
    end
  end

  describe "PATCH assignee" do
    it "admin assegna a un membro" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      patch assignee_member_ticket_path(ticket), params: { assignee_id: member.id }
      expect(ticket.reload.assignee).to eq(member)
    end

    it "id vuoto → disassegna" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, assignee: member, with_agent_workflow: true)
      patch assignee_member_ticket_path(ticket), params: { assignee_id: "" }
      expect(ticket.reload.assignee).to be_nil
    end

    it "membro → redirect (gate), assegnatario invariato" do
      sign_in(member)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      patch assignee_member_ticket_path(ticket), params: { assignee_id: member.id }
      expect(response).to redirect_to(root_path)
      expect(ticket.reload.assignee).to be_nil
    end
  end

  describe "PATCH reviewer" do
    it "admin imposta il revisore su un membro" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      patch reviewer_member_ticket_path(ticket), params: { reviewer_id: member.id }
      expect(ticket.reload.reviewer).to eq(member)
    end

    it "id vuoto → rimuove il revisore" do
      sign_in(admin)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      patch reviewer_member_ticket_path(ticket), params: { reviewer_id: "" }
      expect(ticket.reload.reviewer).to be_nil
    end

    it "membro → redirect (gate), revisore invariato" do
      sign_in(member)
      ticket = create(:ticket, organization: org, project: project, with_agent_workflow: true)
      original = ticket.reviewer
      patch reviewer_member_ticket_path(ticket), params: { reviewer_id: member.id }
      expect(response).to redirect_to(root_path)
      expect(ticket.reload.reviewer).to eq(original)
    end
  end

  # CYRA-393 — il codice del ticket viaggia da solo (rami, commit, chat) e da solo non dice a quale
  # progetto appartiene: 28 prefissi in uso, diversi non derivabili, e due che differiscono per una
  # lettera sola.
  describe "la sigla dice a quale progetto appartiene" do
    let(:ticket) { create(:ticket, organization: org, project:, status:, priority:, with_agent_workflow: true) }

    it "opens the title with the code and keeps the project name under it" do
      sign_in(admin)
      get member_ticket_path(ticket)

      html = Nokogiri::HTML(response.body)
      expect(html.at_css("[data-test='ticket-code']").text).to eq(ticket.code)
      expect(html.at_css("[data-test='ticket-project']").text).to include(ticket.project.name)
    end

    it "passando sopra il codice si legge la sigla per esteso" do
      sign_in(admin)
      get member_ticket_path(ticket)

      titolo = Nokogiri::HTML(response.body).at_css("[data-test='ticket-code']")["title"]
      expect(titolo).to include(ticket.project.key).and include(ticket.project.name)
    end

    it "il titolo della scheda del browser porta il progetto accanto al codice" do
      sign_in(admin)
      get member_ticket_path(ticket)

      titolo = Nokogiri::HTML(response.body).at_css("title").text
      expect(titolo).to include(ticket.code).and include(ticket.project.name)
    end

    # CYRA-883 — the breadcrumb keeps the code only; the project sits next to it under the title.
    it "il percorso mostra il codice e la riga sotto il titolo codice e progetto" do
      sign_in(admin)
      get member_ticket_path(ticket)

      html = Nokogiri::HTML(response.body)
      expect(html.css("[data-test='breadcrumb-crumb']").last.text).to include(ticket.code)
      expect(html.at_css("[data-test='ticket-code']").text).to include(ticket.code)
      expect(html.at_css("[data-test='ticket-project']").text).to include(ticket.project.name)
    end

    it "la pagina del progetto dice qual è la sua sigla" do
      sign_in(admin)
      get member_project_path(ticket.project)

      chip = Nokogiri::HTML(response.body).at_css("[data-test='project-ticket-key']")
      expect(chip.text).to include(ticket.project.key)
    end
  end

  # CYRA-402 — la riga dei comandi allineava fino a nove bottoni tutti uguali: l'approvazione che
  # sblocca il lavoro stava accanto alla cancellazione, che è irreversibile.
  describe "i comandi hanno un peso diverso" do
    let(:ticket) { create(:ticket, organization: org, project:, status:, priority:, with_agent_workflow: true) }
    let(:review_status) { create(:ticket_status, organization: org, review_gate: true) }
    let(:in_review) { create(:ticket, organization: org, project:, status: review_status, priority:, with_agent_workflow: true) }

    it "la decisione in sospeso sale in cima, col contesto e un solo bottone principale" do
      create(:ticket_report, ticket: in_review, organization: org, body: "Fatto e verificato.")
      sign_in(admin)
      get member_ticket_path(in_review)

      pagina = Nokogiri::HTML(response.body)
      banner = pagina.at_css("[data-test='ticket-decision-banner']")
      expect(banner).to be_present
      expect(banner.text).to include(I18n.t("member.tickets.review.banner_title"))
      expect(banner.at_css("[data-test='ticket-review-approve']")).to be_present
      expect(banner.at_css("[data-test='ticket-decision-see']")["href"]).to include("tab=report")
    end

    it "senza decisione in sospeso non compare nessun banner" do
      sign_in(admin)
      get member_ticket_path(ticket)

      expect(Nokogiri::HTML(response.body).at_css("[data-test='ticket-decision-banner']")).to be_nil
    end

    it "modificare ed eliminare stanno in un menu secondario" do
      sign_in(admin)
      get member_ticket_path(ticket)

      menu = Nokogiri::HTML(response.body).at_css("[data-test='ticket-more-menu']")
      expect(menu).to be_present
      dentro = menu.parent.parent
      expect(dentro.at_css("[data-test='ticket-edit']")).to be_present
      expect(dentro.at_css("[data-test='ticket-delete']")).to be_present
    end
  end

  # CYRA-557 — «Vedi cosa ha fatto» portava SEMPRE alla scheda Automazione, che su una lavorazione
  # senza tentativi dichiara di non avere niente da mostrare: il banner prometteva il racconto del
  # lavoro e apriva il vuoto. Il racconto sta nel resoconto e, quando manca, nella discussione.
  describe "il collegamento «Vedi cosa ha fatto»" do
    let(:review_status) { create(:ticket_status, organization: org, review_gate: true) }
    let(:in_review) { create(:ticket, organization: org, project:, status: review_status, priority:, with_agent_workflow: true) }

    def banner_link
      Nokogiri::HTML(response.body).at_css("[data-test='ticket-decision-see']")
    end

    it "porta al resoconto quando c'è" do
      create(:ticket_report, ticket: in_review, organization: org, body: "Ho corretto il salvataggio.")
      sign_in(admin)
      get member_ticket_path(in_review)

      expect(banner_link["href"]).to include("tab=report")
    end

    # Su PFRA-82 il racconto vero stava nei commenti: senza resoconto è lì che si va, non su una
    # scheda che dichiara zero tentativi.
    it "senza resoconto porta alla discussione, se qualcuno ha scritto" do
      create(:ticket_comment, ticket: in_review, organization: org, body: "Rilasciato in staging.")
      sign_in(admin)
      get member_ticket_path(in_review)

      expect(banner_link["href"]).to include("tab=discussion")
    end

    # CYRA-389 — respinto per esteso, il motivo diventa l'ultima stesura del resoconto. Il banner
    # promette «Vedi cosa ha fatto»: mandarlo lì vorrebbe dire aprire la motivazione di chi ha
    # respinto al posto del racconto del lavoro.
    it "una motivazione di respingimento non conta come racconto del lavoro" do
      create(:ticket_report, ticket: in_review, organization: org, source: :review_rejection,
                             body: "Manca il caso limite, e la verifica va rifatta.")
      create(:ticket_comment, ticket: in_review, organization: org, body: "Rilasciato in staging.")
      sign_in(admin)
      get member_ticket_path(in_review)

      expect(banner_link["href"]).to include("tab=discussion")
    end

    it "senza resoconto né commenti porta all'automazione, se ha davvero dei tentativi" do
      workflow = in_review.agent_workflow || create(:agent_workflow, ticket: in_review)
      create(:agent_attempt, workflow:, organization: org, phase: "autopilot")
      sign_in(admin)
      get member_ticket_path(in_review)

      expect(banner_link["href"]).to include("tab=automation")
    end

    # Scenario 3 — la lavorazione non è ancora partita: due pulsanti di decisione su niente sono
    # un invito ad approvare alla cieca. Lo stato del ticket resta modificabile dal pannello Dettagli.
    it "quando non c'è niente da leggere, dice che non c'è niente da approvare e non offre decisioni" do
      sign_in(admin)
      get member_ticket_path(in_review)

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='ticket-decision-banner']")).to be_nil
      expect(pagina.at_css("[data-test='ticket-review-approve']")).to be_nil
      expect(pagina.at_css("[data-test='ticket-review-reject']")).to be_nil
      vuoto = pagina.at_css("[data-test='ticket-decision-nothing']")
      expect(vuoto).to be_present
      expect(vuoto.text).to include(I18n.t("member.tickets.review.nothing_title"))
    end
  end

  # CYRA-405 — analisi e piani erano muri di testo senza autore né data, e senza un modo per
  # accorciarli: ottomila caratteri aperti seppelliscono il resto della pagina.
  describe "l'analisi tecnica si legge" do
    let(:analizzato) do
      create(:ticket, organization: org, project:, status:, priority:,
                      technical_analysis: "## Come\n\nLa logica sta in app/services/foo.rb:33.")
    end

    it "dice chi l'ha scritta e quando" do
      sign_in(admin)
      get member_ticket_path(analizzato, tab: "analysis")

      firma = Nokogiri::HTML(response.body).at_css("[data-test='ticket-analysis-signature']")
      expect(firma).to be_present
      atteso = analizzato.reporter&.name.presence || I18n.t("member.tickets.show.written_by_system")
      expect(firma.text).to include(atteso)
      expect(firma.text).to include(I18n.l(analizzato.created_at, format: :long))
    end

    it "porta titoli e riferimenti ai file con la loro forma" do
      sign_in(admin)
      get member_ticket_path(analizzato, tab: "analysis")

      corpo = Nokogiri::HTML(response.body).at_css("[data-test='ticket-analysis-body']")
      expect(corpo.at_css("h2")).to be_present
      expect(corpo.at_css("code").text).to eq("app/services/foo.rb:33")
    end

    it "offre il comando per vedere tutto il testo" do
      sign_in(admin)
      get member_ticket_path(analizzato, tab: "analysis")

      expect(response.body).to include('data-test="ticket-analysis-toggle"')
      expect(response.body).to include(I18n.t("member.tickets.show.show_all"))
    end

    it "senza analisi non mostra né firma né comando" do
      senza = create(:ticket, organization: org, project:, status:, priority:, technical_analysis: nil)
      sign_in(admin)
      get member_ticket_path(senza, tab: "analysis")

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='ticket-analysis-signature']")).to be_nil
      expect(pagina.at_css("[data-test='ticket-analysis-toggle']")).to be_nil
    end
  end

  # CYRA-408 — il titolo era tagliato a una quarantina di caratteri mentre due colonne mostravano un
  # trattino su ogni riga di ogni pagina, e con dieci righe per pagina mille ticket sono cento pagine.
  describe "l'elenco dà spazio a ciò che serve" do
    it "nasconde scadenza e assegnatario quando nessun risultato le ha, e lo dichiara" do
      create(:ticket, organization: org, project:, status:, priority:, due_at: nil, assignee: nil)
      sign_in(admin)

      get list_member_tickets_path

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='ticket-due-cell']")).to be_nil
      expect(pagina.at_css("[data-test='tickets-hidden-columns']").text).to include(I18n.t("member.tickets.col_due"))
    end

    it "le tiene quando almeno un risultato le valorizza" do
      create(:ticket, organization: org, project:, status:, priority:, due_at: 3.days.from_now)
      sign_in(admin)

      get list_member_tickets_path

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='ticket-due-cell']")).to be_present
      # La nota resta per l'assegnatario, che nessuno di questi risultati ha: dichiara solo ciò che
      # ha davvero nascosto.
      expect(pagina.at_css("[data-test='tickets-hidden-columns']").text).not_to include(I18n.t("member.tickets.col_due"))
    end

    it "si sceglie quante righe vedere, e la scelta resta nell'indirizzo" do
      allow_n_plus_one { bulk_tickets(14, status: status) }
      sign_in(admin)

      get list_member_tickets_path
      expect(Nokogiri::HTML(response.body).css("[data-test='ticket-row']").size).to eq(Pagination::DEFAULT_PER)

      get list_member_tickets_path(per: 25)
      expect(Nokogiri::HTML(response.body).css("[data-test='ticket-row']").size).to eq(14)
    end

    it "un numero fuori dall'elenco ammesso non passa" do
      allow_n_plus_one { bulk_tickets(14, status: status) }
      sign_in(admin)

      get list_member_tickets_path(per: 9999)

      expect(Nokogiri::HTML(response.body).css("[data-test='ticket-row']").size).to eq(Pagination::DEFAULT_PER)
    end
  end

  # CYRA-389 — la pagina prometteva 240 caratteri a chi deve spiegare perché un lavoro non va bene, e
  # non diceva né perché il commento è così corto né dove scrivere per esteso. Ora il commento dichiara
  # la sua misura e il suo perché, e il campo del respingimento dichiara la propria, che è quella del
  # resoconto — il posto in cui la motivazione lunga viene salvata.
  describe "quanto si può scrivere, e dove" do
    let(:review_status) { create(:ticket_status, organization: org, review_gate: true) }
    let(:in_review) { create(:ticket, organization: org, project:, status: review_status, priority:, with_agent_workflow: true) }

    it "la casella del commento dichiara la sua misura e dice dove va il testo lungo" do
      ticket = create(:ticket, organization: org, project:, status:, priority:, with_agent_workflow: true)
      sign_in(admin)

      get member_ticket_path(ticket, tab: "discussion")

      pagina = Nokogiri::HTML(response.body)
      contatore = pagina.at_css("[data-controller='char-counter']")
      expect(contatore["data-char-counter-max-value"]).to eq(Ticketing::Constants::COMMENT_MAX_CHARS.to_s)
      expect(pagina.at_css("[data-test='member-ticket-comment-hint']").text)
        .to include(I18n.t("member.tickets.comments.length_hint"))
    end

    it "il campo del respingimento dichiara il tetto del resoconto, non quello del commento" do
      create(:ticket_report, ticket: in_review, organization: org, body: "Fatto e verificato.")
      sign_in(admin)

      get member_ticket_path(in_review)

      pagina = Nokogiri::HTML(response.body)
      campo = pagina.at_css("[data-test='ticket-review-reject-reason']")
      expect(campo).to be_present
      contatore = campo.ancestors("[data-controller='char-counter']").first
      expect(contatore["data-char-counter-max-value"])
        .to eq(Ticketing::Constants::REVIEW_REASON_MAX_CHARS.to_s)
      expect(pagina.at_css("[data-test='ticket-review-reject-hint']").text)
        .to include(I18n.t("member.tickets.review.reason_hint"))
    end

    it "opens the review rejection in the standard modal shell, with the decision in the header (F24)" do
      create(:ticket_report, ticket: in_review, organization: org, body: "Done and verified.")
      sign_in(admin)

      get member_ticket_path(in_review)

      dialog = Nokogiri::HTML(response.body).at_css("dialog[data-test='ticket-review-reject-modal']")
      expect(dialog["class"]).to include("dark:bg-zinc-950")
      submit = dialog.at_css("header [data-test='ticket-review-reject-submit'], header [data-test='ticket-review-reject-hold']")
      expect(submit).to be_present
      expect(submit.ancestors("form").first["action"]).to eq(member_ticket_review_rejection_path(in_review))
    end

    it "la scheda del resoconto dice quando una stesura è la motivazione di un respingimento" do
      create(:ticket_report, ticket: in_review, organization: org, body: "Fatto e verificato.")
      create(:ticket_report, ticket: in_review, organization: org, source: :review_rejection,
                             body: "Manca il caso limite, e la verifica va rifatta.")
      sign_in(admin)

      get member_ticket_path(in_review, tab: "report")

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='ticket-report-rejection']").text).to include(I18n.t("member.tickets.show.report_rejection"))
      expect(pagina.at_css("[data-test='ticket-report']").text).to include("Manca il caso limite")
    end

    it "una stesura del lavoro resta intitolata resoconto" do
      create(:ticket_report, ticket: in_review, organization: org, body: "Fatto e verificato.")
      sign_in(admin)

      get member_ticket_path(in_review, tab: "report")

      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='ticket-report']").text).to include("Fatto e verificato.")
      expect(pagina.at_css("[data-test='ticket-report-rejection']")).to be_nil
    end
  end
end
