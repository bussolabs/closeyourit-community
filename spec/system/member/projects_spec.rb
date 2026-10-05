# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member projects", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def admin
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  it "un admin crea un progetto" do
    account = admin
    sign_in_as(account)
    visit new_member_project_path
    expect_test "project-form"

    fill_test "project-name", with: "Storefront"
    fill_test "project-key", with: "str"
    fill_test "project-description", with: "Public shop"
    click_on_test "project-submit"

    expect_test "flash-notice"
    expect_test "member-project"
    project = Projects::Project.find_by(key: "STR")
    expect(project).to be_present
    expect(project.name).to eq("Storefront")
    expect(project.created_by).to eq(account)
  end

  it "il dettaglio mostra la striscia degli environment dichiarati e il link gestione token" do
    account = admin
    project = create(:project, organization: org, name: "Storefront")
    env = create(:environment, organization: org, label: "Production", code: "production")
    project.environments << env
    sign_in_as(account)

    visit member_project_path(project)
    find("[data-test='project-about'] summary").click # the information panel starts closed

    expect_test "project-environments"
    expect_test "project-environment"
    expect(page).to have_text("Production")
    expect(page).to have_link(href: member_project_tokens_path(project))
  end

  it "la card informazioni non rende alcun nodo descrizione se il progetto non ha descrizione" do
    sign_in_as(admin)
    project = create(:project, organization: org, description: nil)

    visit member_project_path(project)

    expect_test "member-project"
    expect(page).to have_no_css("[data-test='project-subtitle']")
  end

  it "la card informazioni non rende alcun nodo descrizione se la descrizione è solo spazi" do
    sign_in_as(admin)
    project = create(:project, organization: org, description: "   ")

    visit member_project_path(project)

    expect(page).to have_no_css("[data-test='project-subtitle']")
  end

  it "la card informazioni rende la descrizione quando presente" do
    sign_in_as(admin)
    project = create(:project, organization: org, description: "Backend del negozio")

    visit member_project_path(project)

    expect(page).to have_css("[data-test='project-subtitle']", text: "Backend del negozio")
  end

  it "un admin modifica un progetto" do
    sign_in_as(admin)
    project = create(:project, organization: org, name: "Old", key: "OLD")
    visit edit_member_project_path(project)

    fill_test "project-name", with: "New name"
    click_on_test "project-submit"

    expect_test "flash-notice"
    expect(project.reload.name).to eq("New name")
  end

  it "un admin elimina un progetto dalla tab Settings" do
    sign_in_as(admin)
    project = create(:project, organization: org)

    visit member_project_path(project)
    expect_test "member-project"
    click_on_test "project-tab-more" # CYRA-883: the less used tabs live in the More menu
    click_on_test "project-settings-link"
    expect_test "member-project-settings"
    click_on_test "project-delete"
    conferma_azione_pericolosa

    expect_test "flash-notice"
    expect(Projects::Project).not_to exist(project.id)
  end

  it "un manager vede la danger zone col delete del progetto nella tab Settings" do
    sign_in_as(admin)
    project = create(:project, organization: org)

    visit member_project_path(project)
    click_on_test "project-tab-more" # CYRA-883: the less used tabs live in the More menu
    click_on_test "project-settings-link"
    expect_test "project-danger-zone"
    expect(page).to have_css("[data-test='project-danger-zone'] [data-test='project-delete']")
  end

  it "i pulsanti di azione dell'header restano visibili cambiando tab" do
    sign_in_as(admin)
    project = create(:project, organization: org)

    visit member_project_path(project)
    expect_test "project-new-ticket"
    expect_test "project-new-idea"
    expect_test "project-edit"

    click_on_test "project-tab-more" # CYRA-883: the less used tabs live in the More menu
    click_on_test "project-usage-link"
    expect_test "member-project-usage"
    expect_test "project-new-ticket"
    expect_test "project-new-idea"
    expect_test "project-edit"

    click_on_test "project-tab-more" # CYRA-883: the less used tabs live in the More menu
    click_on_test "project-settings-link"
    expect_test "member-project-settings"
    expect_test "project-new-ticket"
  end

  it "un membro che vede il progetto ma non può gestirlo non raggiunge la danger zone" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    project = create(:project, organization: org)
    create(:project_membership, account: member, project: project)

    sign_in_as(member)
    visit member_project_path(project)

    expect_test "member-project"
    # Niente permesso projects.edit → niente tab Settings → danger zone irraggiungibile
    expect(page).not_to have_css("[data-test='project-settings-link']", visible: :all)
    expect(page).not_to have_css("[data-test='project-danger-zone']")
  end

  it "un membro semplice vede i progetti ma non può gestirli" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    create(:project, organization: org, name: "Storefront")

    sign_in_as(member)
    visit member_projects_path

    expect(page).to have_css("[data-test='member-nav-projects']")
    expect(page).not_to have_css("[data-test='projects-new']")
  end

  it "le card indicano se GitHub è collegato o manca" do
    account = admin
    connected = create(:project, organization: org, name: "Con GitHub")
    disconnected = create(:project, organization: org, name: "Senza GitHub")
    create(:github_repository, project: connected)
    sign_in_as(account)

    visit member_projects_path

    within_test "project-card-#{connected.id}" do
      expect(page).to have_css("[data-test='project-github-status'][aria-label='GitHub connected']")
    end
    within_test "project-card-#{disconnected.id}" do
      expect(page).to have_css("[data-test='project-github-status'][aria-label='GitHub not connected']")
    end
  end

  it "il dettaglio progetto mostra lo stato GitHub nell'header" do
    sign_in_as(admin)
    project = create(:project, organization: org)
    create(:github_repository, project: project)

    visit member_project_path(project)

    expect(page).to have_css("[data-test='project-github-status'][aria-label='GitHub connected']")
  end

  it "un form invalido ri-renderizza con l'errore e non crea il progetto" do
    sign_in_as(admin)
    visit new_member_project_path

    fill_test "project-name", with: ""
    fill_test "project-key", with: ""
    click_on_test "project-submit"

    expect(page).to have_css("[data-test='project-form']") # ri-renderizzato, non redirect
    expect(Projects::Project.count).to eq(0)
  end

  it "il dettaglio mostra le righe ticket (priority high, assegnato e non assegnato)" do
    sign_in_as(admin)
    project = create(:project, organization: org)
    high = create(:ticket_priority, organization: org, code: "high", label: "High", color: "orange")
    open_status = create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber")
    assignee = create(:account)
    create(:membership, account: assignee, organization: org, role: :member)
    create(:ticket, organization: org, project: project, priority: high, status: open_status, assignee: assignee)
    create(:ticket, organization: org, project: project) # default factory: senza assignee, priority non-high

    visit member_project_path(project)
    expect(page).to have_css("[data-test='project-ticket-row']", count: 2)
  end

  it "dal dettaglio progetto apre un ticket col progetto bloccato e lo collega" do
    account = admin
    project = create(:project, organization: org, name: "Storefront", key: "STR")
    create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber")
    create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber")

    sign_in_as(account)
    visit member_project_path(project)
    click_on_test "project-new-ticket"

    expect_test "ticket-form"
    expect_test "ticket-project-locked"
    expect(page).not_to have_css("[data-test='ticket-project']") # nessun select progetto

    fill_test "ticket-title", with: "Bug aperto dal progetto"
    fill_test "ticket-description", with: "risultato atteso"
    click_on_test "ticket-submit"

    expect_test "flash-notice"
    ticket = Ticketing::Ticket.find_by(title: "Bug aperto dal progetto")
    expect(ticket).to be_present
    expect(ticket.project).to eq(project)
  end

  it "le righe ticket nel dettaglio linkano al ticket" do
    sign_in_as(admin)
    project = create(:project, organization: org)
    status = create(:ticket_status, organization: org)
    priority = create(:ticket_priority, organization: org)
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)

    visit member_project_path(project)
    find("[data-test='project-ticket-link']").click

    expect(page).to have_current_path(member_ticket_path(ticket))
  end

  it "la lista vuota mostra l'empty state" do
    sign_in_as(admin) # nessun progetto creato
    visit member_projects_path
    expect_test "projects-empty"
  end

  it "alterna tra vista cards e tabella e la scelta persiste" do
    sign_in_as(admin)
    create(:project, organization: org, name: "Storefront")
    visit member_projects_path
    expect_test "projects-cards"

    find("[data-test='projects-toolbar-view-menu'] summary").click
    click_on_test "projects-view-table"
    expect_test "projects-table"

    # la preferenza persiste tra le richieste
    visit member_projects_path
    expect_test "projects-table"

    find("[data-test='projects-toolbar-view-menu'] summary").click
    click_on_test "projects-view-cards"
    expect_test "projects-cards"
  end

  it "un admin elimina un progetto dal menu della vista tabella" do
    account = admin
    account.update!(projects_view: "table")
    project = create(:project, organization: org)
    sign_in_as(account)

    visit member_projects_path
    expect_test "projects-table"
    # CYRA-924 — delete opens a <dialog> (no JS under rack_test): its red button is reached with visible: :all (F16).
    find("[data-test='project-delete-dialog-#{project.id}-confirm']", visible: :all).click

    expect_test "flash-notice"
    expect(Projects::Project).not_to exist(project.id)
  end

  it "un membro semplice in vista tabella non vede il menu di gestione" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    member.update!(projects_view: "table")
    project = create(:project, organization: org)
    create(:project_membership, account: member, project: project)
    sign_in_as(member)

    visit member_projects_path
    expect_test "projects-table"
    expect(page).not_to have_css("[data-test='project-row-menu-#{project.id}']", visible: :all)
    expect(page).not_to have_css("[data-test='project-row-delete-#{project.id}']", visible: :all)
  end

  def member_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    account
  end

  # Widget select JS-enhanced: integrazione via query param, non guidando il widget (forms-select).
  it "filtra i progetti per piattaforma in vista cards" do
    plat = create(:platform, organization: org, label: "iOS")
    create(:project, organization: org, name: "HasPlatform").platforms << plat
    create(:project, organization: org, name: "NoPlatform")
    sign_in_as(admin)

    visit member_projects_path(platform_id: [ plat.id ])

    expect_test "projects-cards"
    expect(page).to have_text("HasPlatform")
    expect(page).not_to have_text("NoPlatform")
  end

  it "filtra i progetti per piattaforma in vista table" do
    account = admin
    account.update!(projects_view: "table")
    plat = create(:platform, organization: org, label: "Web")
    create(:project, organization: org, name: "HasPlatform").platforms << plat
    create(:project, organization: org, name: "NoPlatform")
    sign_in_as(account)

    visit member_projects_path(platform_id: [ plat.id ])

    expect_test "projects-table"
    expect(page).to have_text("HasPlatform")
    expect(page).not_to have_text("NoPlatform")
  end

  it "filtra la lista ticket nel dettaglio progetto, col titolo sopra la barra filtri" do
    project = create(:project, organization: org)
    open_status = create(:ticket_status, organization: org, code: "open", label: "Open")
    done_status = create(:ticket_status, organization: org, code: "done", label: "Done")
    ticket_open = create(:ticket, organization: org, project: project, status: open_status)
    ticket_done = create(:ticket, organization: org, project: project, status: done_status)
    sign_in_as(admin)

    visit member_project_path(project, status_id: [ open_status.id ])

    expect_test "project-tickets-title"
    expect_test "project-tickets-toolbar"
    expect(page).to have_text(ticket_open.code)
    expect(page).not_to have_text(ticket_done.code)
  end

  # CYRA-16/CYRA-358: la card "Non chiusi" della fascia salute porta alla lista ticket filtrata sugli
  # status non conclusi (categoria da fare + in corso), quindi anche "in revisione"; i ticket conclusi
  # (categoria done) restano fuori.
  it "la card 'Non chiusi' apre la lista ticket filtrata sugli status non conclusi (CYRA-358)" do
    project = create(:project, organization: org)
    open_status = create(:ticket_status, organization: org, code: "open", label: "Open", category: :open, position: 0)
    in_progress = create(:ticket_status, organization: org, code: "in_progress", label: "In Progress", category: :in_progress, position: 1)
    in_review = create(:ticket_status, organization: org, code: "in_review", label: "In Review", category: :in_progress, position: 2)
    done_status = create(:ticket_status, organization: org, code: "resolved", label: "Resolved", category: :done, position: 3)
    create(:ticket, organization: org, project: project, status: open_status)
    create(:ticket, organization: org, project: project, status: in_progress)
    create(:ticket, organization: org, project: project, status: in_review)
    create(:ticket, organization: org, project: project, status: done_status)
    sign_in_as(admin)

    visit member_project_path(project)
    find("[data-test='health-tickets']").click

    # Il link porta esattamente ai 3 status non conclusi (redirect path) e la lista mostra 3 righe:
    # i ticket da fare / in corso / in revisione ci sono, il concluso è escluso (solo data-test).
    expect(page).to have_current_path(
      list_member_tickets_path(project_id: [ project.id ], status_id: [ open_status.id, in_progress.id, in_review.id ])
    )
    expect(page).to have_css("[data-test='ticket-row']", count: 3)
  end

  it "mostra il blocco Audit e la cronologia attività dopo la creazione" do
    account = admin
    sign_in_as(account)
    visit new_member_project_path
    fill_test "project-name", with: "Auditable"
    fill_test "project-key", with: "aud"
    click_on_test "project-submit"

    expect_test "flash-notice"
    within_test("project-audit") do
      expect(page).to have_css("[data-test='audit-created']", text: account.name)
      expect(page).to have_css("[data-test='project-history']")
    end
    # CYRA-827 — il modale è nel DOM (aperto via <dialog> nativo), ma le righe non ci sono ancora:
    # la cronologia si carica quando il riquadro si apre davvero. Senza JavaScript quel caricamento
    # non avviene mai, e allora conta l'altra strada — il collegamento di ripiego, che è anche la via
    # di recupero quando il riquadro non arriva. Che si carichi da sé lo prova l'esempio `js: true`.
    expect(page).to have_css("[data-test='activity-modal']", visible: :all)
    expect(page).to have_no_css("[data-test='activity-row']", visible: :all)

    find("[data-test='activity-history-fallback']", visible: :all).click
    expect_test "member-project-history"
    expect(page).to have_css("[data-test='activity-row']", minimum: 1)
    # E da lì si torna al progetto: la cronologia non è un vicolo cieco.
    click_on_test "project-history-back"
    expect_test "member-project"
  end

  describe "link al repository GitHub nella card Informazioni" do
    it "mostra il link (owner/repo) cliccabile verso github.com quando c'è un repo collegato" do
      sign_in_as(admin)
      project = create(:project, organization: org)
      create(:github_repository, project: project, full_name: "bussolabs/closeyourit-rails")

      visit member_project_path(project)
      find("[data-test='project-about'] summary").click # the information panel starts closed

      link = find("[data-test='project-repository-link']")
      expect(link).to have_text("bussolabs/closeyourit-rails")
      expect(link[:href]).to eq("https://github.com/bussolabs/closeyourit-rails")
    end

    it "non mostra la riga repository quando nessun repo è collegato" do
      sign_in_as(admin)
      project = create(:project, organization: org)

      visit member_project_path(project)

      expect(page).to have_css("[data-test='member-project']")
      expect(page).to have_no_css("[data-test='project-repository']")
    end
  end

  describe "sezione uptime gated dalla capability piattaforma" do
    it "un progetto con piattaforma web mostra la sezione Uptime (environment sempre presenti)" do
      sign_in_as(admin)
      project = create(:project, organization: org)
      project.platforms << create(:platform, :uptime_capable, organization: org)
      create(:environment, organization: org).tap { |e| project.environments << e }

      visit member_project_path(project)
      find("[data-test='project-about'] summary").click # the information panel starts closed

      expect_test "project-uptime"
      expect_test "project-environments"
    end

    it "un progetto solo-mobile non mostra l'uptime ma mostra gli environment" do
      sign_in_as(admin)
      project = create(:project, organization: org)
      project.platforms << create(:platform, organization: org) # nativa (no uptime)
      create(:environment, organization: org).tap { |e| project.environments << e }

      visit member_project_path(project)
      find("[data-test='project-about'] summary").click # the information panel starts closed

      expect(page).to have_no_css("[data-test='project-uptime']")
      expect_test "project-environments"
    end
  end
end
