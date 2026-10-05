# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member tickets", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let!(:status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber") }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def admin_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  it "un admin crea un ticket (form strutturato)" do
    account = admin_account
    sign_in_as(account)
    visit new_member_ticket_path
    expect_test "ticket-form"

    select "Storefront", from: "project_id"
    fill_test "ticket-title", with: "Checkout broken on Safari"
    fill_test "ticket-description", with: "checkout proceeds"
    click_on_test "ticket-submit"

    expect_test "flash-notice"
    expect_test "member-ticket"
    ticket = Ticketing::Ticket.find_by(title: "Checkout broken on Safari")
    expect(ticket).to be_present
    expect(ticket.reporter).to eq(account)
    expect(ticket.description).to eq("checkout proceeds")
  end

  it "un admin crea un ticket con scadenza (due_at) e la vede in tabella" do
    account = admin_account
    sign_in_as(account)
    visit new_member_ticket_path

    select "Storefront", from: "project_id"
    fill_test "ticket-title", with: "Task con scadenza"
    fill_test "ticket-description", with: "atteso"
    fill_test "ticket-due-at", with: "2026-08-01T17:00"
    click_on_test "ticket-submit"

    expect_test "flash-notice"
    ticket = Ticketing::Ticket.find_by(title: "Task con scadenza")
    expect(ticket.due_at.strftime("%Y-%m-%d %H:%M")).to eq("2026-08-01 17:00")

    visit list_member_tickets_path
    expect_test "ticket-created-cell"
    expect_test "ticket-due-cell"
    expect(page).to have_css("[data-test='ticket-due-cell']", text: I18n.l(ticket.due_at, format: :long))
  end

  it "un admin cambia lo status dal dettaglio (senza tornare alla board)" do
    account = admin_account
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)
    closed = create(:ticket_status, organization: org, code: "closed", label: "Closed", color: "gray")

    sign_in_as(account)
    visit member_ticket_path(ticket)
    find("[data-test='ticket-status-#{closed.id}']", visible: :all).click

    expect_test "flash-notice"
    within_test("ticket-status") { expect(page).to have_text("Closed") }
    expect(ticket.reload.status).to eq(closed)
  end

  it "un customer vede lo status in sola lettura, nessun controllo di modifica" do
    customer = create(:account)
    create(:membership, account: customer, organization: org, role: :customer)
    create(:project_membership, account: customer, project: project)
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)

    sign_in_as(customer)
    visit member_ticket_path(ticket)

    within_test("detail-status") { expect(page).to have_text("Open") }
    expect(page).to have_no_css("[data-test='ticket-status']", visible: :all)
  end

  it "dal dettaglio, un prerequisito aperto rifiuta il cambio stato (dependency guard) e lo status resta invariato" do
    account = admin_account
    in_progress = create(:ticket_status, :in_progress, organization: org)
    blocker = create(:ticket, organization: org, project: project, status: status, priority: priority)
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)
    create(:ticket_dependency, ticket: ticket, blocker: blocker)

    sign_in_as(account)
    visit member_ticket_path(ticket)
    find("[data-test='ticket-status-#{in_progress.id}']", visible: :all).click

    expect_test "flash-alert"
    within_test("ticket-status") { expect(page).to have_text("Open") }
    expect(ticket.reload.status).to eq(status)
  end

  it "mostra il blocco Audit (created + updated) e il link alla cronologia" do
    account = admin_account
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)

    sign_in_as(account)
    visit member_ticket_path(ticket)

    within_test("ticket-audit") do
      expect(page).to have_css("[data-test='audit-created']")
      expect(page).to have_css("[data-test='audit-updated']")
      expect(page).to have_css("[data-test='ticket-history']")
    end
    # Il modale cronologia è presente nel DOM (aperto via <dialog> nativo).
    expect(page).to have_css("[data-test='ticket-activity-modal']", visible: :all)
  end

  it "la show rende gli scenari con label a sinistra e salta gli step vuoti" do
    account = admin_account
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority,
                    with_default_body: false, description: "Corpo libero")
    create(:ticketing_scenario, ticket: ticket, title: "Happy",
           step_given: "Safari 17 con carrello", step_when: "clicco Checkout",
           step_then: "non succede nulla", step_expected: "vado al pagamento")
    create(:ticketing_scenario, ticket: ticket, title: "Edge",
           step_given: "", step_when: "riprovo", step_then: "errore 500", step_expected: "")

    sign_in_as(account)
    visit member_ticket_path(ticket)

    within_test("ticket-scenarios") do
      # Label corte a sinistra (non più la copy lunga "Given — contesto").
      expect(page).to have_text("Given")
      expect(page).to have_no_text("Given — contesto")
      # Valore mostrato accanto alla sua label.
      expect(page).to have_css("[data-test='ticket-scenario-step-given']", text: "Safari 17 con carrello")
      expect(page).to have_css("[data-test='ticket-scenario-step-expected']", text: "vado al pagamento")
      # Gli step vuoti del secondo scenario sono saltati: given/expected 1 sola volta, when/then 2.
      expect(page).to have_css("[data-test='ticket-scenario-step-given']", count: 1)
      expect(page).to have_css("[data-test='ticket-scenario-step-when']", count: 2)
      expect(page).to have_css("[data-test='ticket-scenario-step-expected']", count: 1)
    end
  end

  it "un admin assegna il ticket inline" do
    account = admin_account
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)
    assignee = create(:account)
    create(:membership, account: assignee, organization: org, role: :member)

    sign_in_as(account)
    visit member_ticket_path(ticket)
    find("[data-test='ticket-assignee-#{assignee.id}']", visible: :all).click

    expect(ticket.reload.assignee).to eq(assignee)
  end

  it "un admin elimina un ticket dal dettaglio" do
    account = admin_account
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)

    sign_in_as(account)
    visit member_ticket_path(ticket)
    # CYRA-402: eliminare è raro e irreversibile, sta nel menu delle altre azioni.
    click_on_test "ticket-more-menu"
    click_on_test "ticket-delete"

    expect_test "flash-notice"
    expect(Ticketing::Ticket).not_to exist(ticket.id)
  end

  it "un customer vede i ticket e può aprirne uno" do
    customer = create(:account)
    create(:membership, account: customer, organization: org, role: :customer)
    create(:project_membership, account: customer, project: project)

    sign_in_as(customer)
    visit member_tickets_path
    expect(page).to have_css("[data-test='member-nav-tickets']")
    expect(page).to have_css("[data-test='tickets-new']") # può creare

    visit new_member_ticket_path
    select "Storefront", from: "project_id"
    fill_test "ticket-title", with: "Customer reported bug"
    fill_test "ticket-description", with: "expected result"
    click_on_test "ticket-submit"

    expect_test "flash-notice"
    ticket = Ticketing::Ticket.find_by(title: "Customer reported bug")
    expect(ticket.reporter).to eq(customer)
  end

  it "filtra per status via URL (param array, non guidando il widget)" do
    account = admin_account
    closed = create(:ticket_status, organization: org, code: "closed", label: "Closed", color: "gray")
    create(:ticket, organization: org, project: project, status: status, priority: priority)
    create(:ticket, organization: org, project: project, status: closed, priority: priority)

    sign_in_as(account)
    visit list_member_tickets_path(status_id: [ status.id ])

    expect(page).to have_css("[data-test='ticket-row']", count: 1)
    # Chip filtri server-rendered: attivo (param nei GET) visibile, inattivo con attributo
    # hidden (che rack_test rispetta: serve visible: :all per trovarlo).
    expect(page).to have_css("[data-test='filter-chip-status_id']:not([hidden])")
    expect(page).to have_css("[data-test='filter-chip-kind'][hidden]", visible: :all)
    expect(page).to have_css("[data-test='tickets-toolbar-filters-menu']")
  end

  it "la lista vuota mostra l'empty state" do
    sign_in_as(admin_account)
    visit list_member_tickets_path
    expect_test "tickets-empty"
  end

  it "la board raggruppa le card nella colonna dello status giusto" do
    closed = create(:ticket_status, organization: org, code: "closed", label: "Closed", color: "gray")
    open_ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)
    closed_ticket = create(:ticket, organization: org, project: project, status: closed, priority: priority)

    sign_in_as(admin_account)
    visit member_tickets_path

    expect_test "board-column-open"
    expect_test "board-column-closed"
    within_test("board-column-open") { expect(page).to have_css("[data-test='board-card-#{open_ticket.id}']") }
    within_test("board-column-closed") { expect(page).to have_css("[data-test='board-card-#{closed_ticket.id}']") }
  end

  it "un admin modifica un ticket dal form" do
    account = admin_account
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority, title: "Old title")

    sign_in_as(account)
    visit edit_member_ticket_path(ticket)
    expect_test "ticket-form"
    fill_test "ticket-title", with: "Updated title"
    click_on_test "ticket-submit"

    expect_test "flash-notice"
    expect(ticket.reload.title).to eq("Updated title")
  end

  it "board: le card sono trascinabili per admin/owner" do
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)
    sign_in_as(admin_account)
    visit member_tickets_path
    expect(page).to have_css("[data-test='board-card-#{ticket.id}'][draggable='true']")
  end

  it "board: le card NON sono trascinabili per un member (read-only)" do
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    sign_in_as(member)
    visit member_tickets_path
    expect(page).to have_css("[data-test='board-card-#{ticket.id}'][draggable='false']")
  end

  it "board: no tip bubble and no tips panel" do
    create(:ticket, organization: org, project: project, status: status, priority: priority)
    sign_in_as(admin_account)
    visit member_tickets_path
    expect(page).to have_no_css("[data-test='board-header-title-tip']")
    expect(page).to have_no_css("[data-test='member-tickets-board-tips']")
  end

  describe "Fase 4 — kind" do
    it "il form mostra il selettore kind, la descrizione e il corpo (scenari, DoD, analisi tecnica) per tutti i kind" do
      sign_in_as(admin_account)
      visit new_member_ticket_path
      expect_test "ticket-kind"
      expect_test "ticket-kind-story"
      # Corpo human-simple + registro tecnico separato, uguali per tutti i kind.
      expect_test "ticket-description"
      expect_test "ticket-scenarios"
      expect_test "ticket-conditions"
      expect_test "ticket-technical-analysis"
    end

    it "la lista ticket mostra il badge kind per riga" do
      create(:ticket, :story, organization: org, project: project, status: status, priority: priority, title: "Dark mode")
      sign_in_as(admin_account)
      visit list_member_tickets_path
      expect_test "ticket-kind-cell"
      expect(page).to have_text("Dark mode")
    end
  end

  # CYRA-1 — header identico tra board (/member/tickets) e lista (/member/tickets/list):
  # stessi chip conteggi (totale + in corso) e stesse azioni (Chiedi ai ticket + nuovo +
  # cross-navigazione speculare). Setup: 1 ticket open + 2 in corso.
  describe "CYRA-1 — header identico tra board e lista" do
    let!(:doing) { create(:ticket_status, organization: org, code: "doing", label: "Doing", color: "indigo", category: :in_progress) }

    before do
      create(:ticket, organization: org, project: project, status: status, priority: priority)
      create(:ticket, organization: org, project: project, status: doing, priority: priority)
      create(:ticket, organization: org, project: project, status: doing, priority: priority)
    end

    it "la lista mostra il chip 'in corso' oltre al totale (stessa coppia di chip della board)" do
      sign_in_as(admin_account)
      visit list_member_tickets_path

      expect(page).to have_css("[data-test='tickets-count-tickets']", text: "3")
      expect(page).to have_css("[data-test='tickets-count-in-progress']", text: "2")
    end

    it "la lista espone il bottone Chiedi ai ticket, il bottone board e nuovo (azioni allineate alla board)" do
      sign_in_as(admin_account)
      visit list_member_tickets_path

      expect(page).to have_css("[data-test='tickets-ask'][href='#{ask_member_tickets_path}']")
      expect(page).to have_css("[data-test='tickets-view-board']", visible: :all)
      expect(page).to have_css("[data-test='tickets-new']")
    end

    it "board e lista mostrano gli stessi valori nei chip conteggi (senza filtri)" do
      sign_in_as(admin_account)

      visit member_tickets_path
      expect(page).to have_css("[data-test='board-stat-tickets']", text: "3")
      expect(page).to have_css("[data-test='board-stat-in-progress']", text: "2")

      visit list_member_tickets_path
      expect(page).to have_css("[data-test='tickets-count-tickets']", text: "3")
      expect(page).to have_css("[data-test='tickets-count-in-progress']", text: "2")
    end
  end

  # CYRA-65 — i metadati del ticket (codice, tipologia, status, gravità, assegnatario, revisore,
  # segnalatore, progetto, milestone, peso, scadenza, piattaforme) vivono nel pannello "Dettagli"
  # nella colonna destra (modellato sugli error group), NON più come pill sotto il titolo. Sotto il
  # titolo resta solo il TTL "aperto da". Rivede la direzione di CYRA-23/CYRA-25.
  describe "CYRA-65 — metadati nel pannello Dettagli a destra, TTL sotto il titolo" do
    it "rende i metadati nel pannello Dettagli della colonna destra" do
      account = admin_account
      assignee = create(:account, name: "Mara Verdi")
      create(:membership, account: assignee, organization: org, role: :member)
      milestone = create(:milestone, project: project, label: "v2.0")
      ticket = create(:ticket, organization: org, project: project, status: status, priority: priority,
                      assignee: assignee, milestone: milestone, weight: 5)

      sign_in_as(account)
      visit member_ticket_path(ticket)

      # Il codice del ticket NON è un metadato del pannello: sta nel breadcrumb dell'header e basta,
      # ripeterlo qui era la stessa informazione due volte a mezzo schermo di distanza.
      expect(page).to have_css("nav[aria-label='breadcrumb']", text: ticket.code)

      within_test("ticket-details") do
        expect(page).not_to have_css("[data-test='detail-code']")
        expect(page).to have_css("[data-test='detail-kind']", text: "Bug")
        within_test("ticket-status") { expect(page).to have_text("Open") }
        expect(page).to have_css("[data-test='detail-priority']", text: "Medium")
        expect(page).to have_css("[data-test='detail-assignee']", text: "Mara Verdi")
        expect(page).to have_css("[data-test='detail-reviewer']")
        expect(page).to have_css("[data-test='detail-reporter']", text: ticket.reporter.name)
        # CYRA-883 — the project is not repeated here: it sits next to the code under the title.
        expect(page).not_to have_css("[data-test='detail-project']")
        expect(page).to have_css("[data-test='detail-milestone']", text: "v2.0")
        expect(page).to have_css("[data-test='detail-weight']", text: "5")
      end
    end

    it "shows the opening age and mobile summary below the title without metadata pills" do
      account = admin_account
      ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)

      sign_in_as(account)
      visit member_ticket_path(ticket)

      within_test("ticket-header-counts") do
        expect(page).to have_css("[data-test='ticket-open-since']")
      end
      # CYRA-819 — stato e priorità in sola lettura, spenti da lg in su: su schermo largo il posto
      # resta il pannello Dettagli, quindi qui si cerca anche ciò che non si vede. It sits in the
      # title block, before the actions (DESIGN.md T2), not among the counts.
      expect(page).to have_css("[data-test='page-header-title-row'] [data-test='ticket-mobile-summary']",
                              visible: :all, count: 1)
      # I metadati non sono più pill sotto il titolo (slot meta rimosso).
      expect(page).to have_no_css("[data-test='ticket-header-meta']", visible: :all)
    end

    it "preserva i target id realtime (status/assignee/reviewer) nel pannello Dettagli" do
      account = admin_account
      assignee = create(:account, name: "Mara Verdi")
      create(:membership, account: assignee, organization: org, role: :member)
      ticket = create(:ticket, organization: org, project: project, status: status, priority: priority, assignee: assignee)

      sign_in_as(account)
      visit member_ticket_path(ticket)

      dom = ActionView::RecordIdentifier.dom_id(ticket)
      within_test("ticket-details") do
        expect(page).to have_css("##{dom}_status", visible: :all)
        expect(page).to have_css("##{dom}_assignee", visible: :all)
        expect(page).to have_css("##{dom}_reviewer", visible: :all)
      end
    end

    it "l'assegnazione inline resta disponibile dal pannello Dettagli (dropdown)" do
      account = admin_account
      assignee = create(:account)
      create(:membership, account: assignee, organization: org, role: :member)
      ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)

      sign_in_as(account)
      visit member_ticket_path(ticket)

      within_test("ticket-details") do
        find("[data-test='ticket-assignee-#{assignee.id}']", visible: :all).click
      end

      expect(ticket.reload.assignee).to eq(assignee)
    end

    it "un customer vede i metadati nel pannello in sola lettura (nessun dropdown di gestione)" do
      customer = create(:account)
      create(:membership, account: customer, organization: org, role: :customer)
      create(:project_membership, account: customer, project: project)
      assignee = create(:account, name: "Lea Bianchi")
      create(:membership, account: assignee, organization: org, role: :member)
      ticket = create(:ticket, organization: org, project: project, status: status, priority: priority, assignee: assignee)

      sign_in_as(customer)
      visit member_ticket_path(ticket)

      within_test("ticket-details") do
        expect(page).to have_css("[data-test='detail-assignee']", text: "Lea Bianchi")
      end
      # Nessun controllo di modifica per chi non gestisce.
      expect(page).to have_no_css("[data-test='ticket-assignee']", visible: :all)
    end
  end
end
