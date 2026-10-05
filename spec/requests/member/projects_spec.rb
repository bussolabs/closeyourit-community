# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Projects", type: :request do
  let(:org) { create(:organization) }

  # I tre attori nascono con la loro membership solo quando un esempio li nomina (CYRA-551): quasi
  # ogni esempio ne usa uno, e un `before` comune faceva pagare a tutti tre account e tre membership.
  let(:owner) { account_with_membership(:owner) }
  let(:admin) { account_with_membership(:admin) }
  let(:member) { account_with_membership(:member) }

  def account_with_membership(role)
    create(:account).tap { |account| create(:membership, account: account, organization: org, role: role) }
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Progetto uptime-capable nell'org di test con un environment dichiarato e un host collegato.
  def linked_project_graph
    project = create(:project, organization: org)
    project.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    environment = create(:environment, organization: org)
    project.environments << environment
    create(:environment_host, project:, environment:, host: create(:server_host, organization: org))
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_projects_path
      expect(response).to redirect_to(login_path)
    end

    it "membro semplice → 200" do
      sign_in(member)
      create(:project, organization: org)
      get member_projects_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET show" do
    it "membro assegnato → 200" do
      sign_in(member)
      project = create(:project, organization: org)
      create(:project_membership, account: member, project: project)
      get member_project_path(project)
      expect(response).to have_http_status(:ok)
    end

    it "mostra il pulsante «Nuova idea» collegato al progetto" do
      sign_in(member)
      project = create(:project, organization: org)
      create(:project_membership, account: member, project: project)
      get member_project_path(project)
      expect(response.body).to include('data-test="project-new-idea"')
      expect(response.body).to include(new_member_idea_path(project_id: project.id))
    end

    it "membro non assegnato → 404 (strict scoping)" do
      sign_in(member)
      project = create(:project, organization: org)
      get member_project_path(project)
      expect(response).to have_http_status(:not_found)
    end

    it "membro assegnato a un GRUPPO → vede i progetti del gruppo (anche futuri)" do
      sign_in(member)
      group = create(:group, organization: org)
      create(:group_membership, account: member, group: group)
      project = create(:project, organization: org, group: group)
      get member_project_path(project)
      expect(response).to have_http_status(:ok)
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      sign_in(owner)
      foreign = create(:project, organization: create(:organization))
      get member_project_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "mostra la striscia degli environment dichiarati + il link gestione token (manager)" do
      sign_in(owner)
      project = create(:project, organization: org)
      env = create(:environment, organization: org, label: "Production")
      project.environments << env
      get member_project_path(project)
      expect(response.body).to include("project-environments")
      expect(response.body).to include("Production")
      expect(response.body).to include(member_project_tokens_path(project))
    end

    # CYRA-63: la gestione server è nella tab Environments; la panoramica è in sola lettura → non
    # mostra più la card server (né form, né chip di gestione).
    it "la panoramica NON mostra la card server (gestione spostata nella tab Environments)" do
      sign_in(owner)
      link = linked_project_graph
      create(:server_host, organization: org, name: "free-host")
      get member_project_path(link.project)
      expect(response.body).not_to include('data-test="project-servers"')
      expect(response.body).not_to include("project-servers-submit-#{link.environment_id}")
    end
  end

  describe "GET new" do
    it "admin → 200" do
      sign_in(owner)
      get new_member_project_path
      expect(response).to have_http_status(:ok)
    end

    it "membro semplice → redirect (403 gate)" do
      sign_in(member)
      get new_member_project_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST create" do
    it "admin crea un progetto (reporter creator = account)" do
      sign_in(owner)
      expect do
        post member_projects_path, params: { name: "Storefront", key: "str", color: "indigo", description: "Shop" }
      end.to change(Projects::Project, :count).by(1)
      project = Projects::Project.last
      expect(project.key).to eq("STR")
      expect(project.created_by).to eq(owner)
      expect(response).to redirect_to(member_project_path(project))
    end

    it "membro semplice → redirect, nessun progetto creato" do
      sign_in(member)
      expect do
        post member_projects_path, params: { name: "X", key: "X" }
      end.not_to change(Projects::Project, :count)
      expect(response).to redirect_to(root_path)
    end

    it "dati invalidi → 422 render new" do
      sign_in(owner)
      post member_projects_path, params: { name: "", key: "" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "admin assegna il progetto a un gruppo della stessa org" do
      sign_in(owner)
      group = create(:group, organization: org)
      post member_projects_path, params: { name: "Grouped", key: "GRP", group_id: group.id }
      expect(Projects::Project.last.group).to eq(group)
    end

    it "scarta un group_id di un'altra org (anti-BOLA)" do
      sign_in(owner)
      foreign_group = create(:group, organization: create(:organization))
      post member_projects_path, params: { name: "Grouped", key: "GRP2", group_id: foreign_group.id }
      expect(Projects::Project.last.group).to be_nil
    end

    it "dichiara gli environment dell'org sul progetto" do
      sign_in(owner)
      env = create(:environment, organization: org)
      post member_projects_path, params: { name: "WithEnv", key: "WENV", environment_ids: [ env.id ] }
      expect(Projects::Project.last.environments).to contain_exactly(env)
    end

    it "scarta un environment_id di un'altra org (anti-BOLA)" do
      sign_in(owner)
      foreign_env = create(:environment, organization: create(:organization))
      post member_projects_path, params: { name: "WithEnv", key: "WEN2", environment_ids: [ foreign_env.id ] }
      expect(Projects::Project.last.environments).to be_empty
    end

    it "salva l'icona Font Awesome scelta" do
      sign_in(owner)
      post member_projects_path, params: { name: "Iconed", key: "ICN", icon: "rocket" }
      expect(Projects::Project.last.icon).to eq("rocket")
    end

    it "salva l'immagine icona caricata" do
      sign_in(owner)
      file = fixture_file_upload("screenshot.png", "image/png")
      post member_projects_path, params: { name: "Imaged", key: "IMG", icon_image: file }
      expect(Projects::Project.last.icon_image).to be_attached
    end

    it "secret_approval_enabled è false di default (opt-in)" do
      sign_in(owner)
      post member_projects_path, params: { name: "Plain", key: "PLN" }
      expect(Projects::Project.last.secret_approval_enabled?).to be(false)
    end

    it "attiva secret_approval_enabled in creazione (CYRA-138)" do
      sign_in(owner)
      post member_projects_path, params: { name: "Protected", key: "PRT", secret_approval_enabled: "1" }
      expect(Projects::Project.last.secret_approval_enabled?).to be(true)
    end
  end

  describe "GET edit" do
    it "admin → 200" do
      sign_in(owner)
      project = create(:project, organization: org)
      get edit_member_project_path(project)
      expect(response).to have_http_status(:ok)
    end

    it "membro non assegnato → 404 (non vede il progetto, set_project prima del gate)" do
      sign_in(member)
      project = create(:project, organization: org)
      get edit_member_project_path(project)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH update" do
    it "admin aggiorna nome/descrizione" do
      sign_in(owner)
      project = create(:project, organization: org, name: "Old")
      patch member_project_path(project), params: { name: "New", key: project.key, description: "Desc" }
      expect(response).to redirect_to(member_project_path(project))
      expect(project.reload.name).to eq("New")
      expect(project.description).to eq("Desc")
    end

    it "nome vuoto → 422" do
      sign_in(owner)
      project = create(:project, organization: org, name: "Old")
      patch member_project_path(project), params: { name: "", key: project.key }
      expect(response).to have_http_status(:unprocessable_content)
      expect(project.reload.name).to eq("Old")
    end

    it "attiva/disattiva secret_approval_enabled in aggiornamento (CYRA-138)" do
      sign_in(owner)
      project = create(:project, organization: org, secret_approval_enabled: false)
      patch member_project_path(project), params: { name: project.name, key: project.key, secret_approval_enabled: "1" }
      expect(project.reload.secret_approval_enabled?).to be(true)

      patch member_project_path(project), params: { name: project.name, key: project.key, secret_approval_enabled: "0" }
      expect(project.reload.secret_approval_enabled?).to be(false)
    end
  end

  describe "DELETE destroy" do
    it "admin elimina il progetto e i suoi ticket (cascade)" do
      sign_in(owner)
      project = create(:project, organization: org)
      create(:ticket, organization: org, project: project)
      expect do
        delete member_project_path(project), params: { confirm: "1" }
      end.to change(Projects::Project, :count).by(-1).and change(Ticketing::Ticket, :count).by(-1)
      expect(response).to redirect_to(member_projects_path)
    end

    it "membro non assegnato → 404, progetto resta" do
      sign_in(member)
      project = create(:project, organization: org)
      expect do
        delete member_project_path(project)
      end.not_to change(Projects::Project, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET index — risoluzione vista (cards/table)" do
    before do
      project = create(:project, organization: org)
      create(:project_membership, account: member, project: project)
    end

    it "senza preferenze → vista cards di default" do
      sign_in(member)
      get member_projects_path
      expect(response.body).to include('data-test="projects-cards"')
      expect(response.body).not_to include('data-test="projects-table"')
    end

    it "preferenza utente 'table' → vista table" do
      member.update!(projects_view: "table")
      sign_in(member)
      get member_projects_path
      expect(response.body).to include('data-test="projects-table"')
      expect(response.body).not_to include('data-test="projects-cards"')
    end

    it "senza preferenza utente ma default org 'table' → vista table" do
      org.update!(default_projects_view: "table")
      sign_in(member)
      get member_projects_path
      expect(response.body).to include('data-test="projects-table"')
    end

    it "la preferenza utente prevale sul default org" do
      org.update!(default_projects_view: "table")
      member.update!(projects_view: "cards")
      sign_in(member)
      get member_projects_path
      expect(response.body).to include('data-test="projects-cards"')
      expect(response.body).not_to include('data-test="projects-table"')
    end

    it "la scelta via endpoint preferenze persiste tra due richieste" do
      sign_in(member)
      get member_projects_path
      expect(response.body).to include('data-test="projects-cards"')

      patch member_preferences_path, params: { projects_view: "table" }
      get member_projects_path
      expect(response.body).to include('data-test="projects-table"')
    end

    # CYRA-924 — cards or table is a choice of the View menu (C62), never buttons in the bar: each choice
    # submits the saved preference, and the current one carries the check.
    it "offers cards and table in the View menu, as preference buttons" do
      sign_in(member)
      get member_projects_path
      doc = Nokogiri::HTML(response.body)

      menu = doc.at_css("[data-test='projects-toolbar-view-menu']")
      cards = menu.at_css("button[data-test='projects-view-cards']")
      table = menu.at_css("button[data-test='projects-view-table']")
      expect(cards["form"]).to eq("projects-view-cards-form")
      expect(table["form"]).to eq("projects-view-table-form")
      expect(cards["aria-current"]).to eq("true")
      expect(table["aria-current"]).to be_nil
      expect(doc.at_css("[data-test='projects-view-toggle']")).to be_nil
    end
  end

  describe "GET index — search e paginazione" do
    it "filtra per nome" do
      sign_in(member)
      alpha = create(:project, organization: org, name: "Alpha Storefront")
      zeta = create(:project, organization: org, name: "Zeta Backend")
      create(:project_membership, account: member, project: alpha)
      create(:project_membership, account: member, project: zeta)
      get member_projects_path, params: { q: "storefront" }
      expect(response.body).to include("Alpha Storefront")
      expect(response.body).not_to include("Zeta Backend")
    end

    it "pagina (vista table): la seconda pagina è diversa dalla prima" do
      member.update!(projects_view: "table")
      sign_in(member)
      30.times do |i|
        project = create(:project, organization: org, name: "Proj #{format('%02d', i)}")
        create(:project_membership, account: member, project: project)
      end
      get member_projects_path, params: { page: 1 }
      page1 = response.body
      get member_projects_path, params: { page: 2 }
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to eq(page1)
    end

    it "cards view: 12 cards, and Show more reaches the ones after (D23)" do
      sign_in(member)
      projects = Array.new(15) do |i|
        project = create(:project, organization: org, name: "Proj #{format('%02d', i)}")
        create(:project_membership, account: member, project: project)
        project
      end
      get member_projects_path
      expect(response.body.scan('data-test="project-card-').size).to eq(12)
      expect(response.body).not_to include(%(data-test="project-card-#{projects.last.id}"))

      get member_projects_path, params: { limit: 24 }
      expect(response.body.scan('data-test="project-card-').size).to eq(15)
      expect(response.body).to include(%(data-test="project-card-#{projects.last.id}"))
    end

    # CYRA-924 — no sort select in the bar (C9): the table sorts on its columns, the cards from the View menu.
    it "sorts the cards from the View menu, keeping the filters, and checks the current order" do
      sign_in(member)
      create(:project_membership, account: member, project: create(:project, organization: org))
      get member_projects_path, params: { q: "a", sort: "-errors" }
      menu = Capybara.string(response.body).find("[data-test='projects-toolbar-view-menu']")

      errors = menu.find("a[data-test='projects-sort--errors']", visible: :all)
      expect(errors["aria-current"]).to eq("true")
      expect(menu.find("a[data-test='projects-sort-name']", visible: :all)["href"]).to eq(member_projects_path(q: "a", sort: "name"))
      expect(Capybara.string(response.body)).to have_no_css("[data-test='projects-toolbar'] select[name='sort']")
    end

    it "offers no card order in the table view, and keeps a column sort across searches" do
      member.update!(projects_view: "table")
      sign_in(member)
      create(:project_membership, account: member, project: create(:project, organization: org))
      get member_projects_path, params: { sort: "-group" }
      html = Capybara.string(response.body)

      expect(html).to have_no_css("[data-test^='projects-sort-']")
      expect(html).to have_css("[data-test='projects-toolbar'] input[type='hidden'][name='sort'][value='-group']", visible: :all)
    end

    it "shows no project count in the search bar" do
      sign_in(member)
      create(:project_membership, account: member, project: create(:project, organization: org))
      get member_projects_path
      toolbar = Capybara.string(response.body).find("[data-test='projects-toolbar']")
      expect(toolbar).to have_no_text(I18n.t("member.projects.count", count: 1))
    end
  end

  # CYRA-883 — the card says how the project is doing, so the list answers without opening each one.
  describe "GET index — card health" do
    before { sign_in(owner) }

    it "shows open errors, availability and last release on the card" do
      project = create(:project, organization: org)
      create_list(:error_group, 2, project:)
      create(:uptime_monitor, :down, project:, last_checked_at: Time.current)
      create(:release, project:, version: "v2.4.0")

      get member_projects_path

      card = Capybara.string(response.body).find("[data-test='project-card-#{project.id}']")
      expect(card.find("[data-test='project-health-errors']")).to have_text(I18n.t("member.projects.card.errors", count: 2))
      expect(card.find("[data-test='project-health-uptime']")).to have_text(I18n.t("member.projects.card.uptime.down"))
      expect(card.find("[data-test='project-health-release']")).to have_text("v2.4.0")
    end

    it "says a quiet project has no errors and shows no availability without a monitor" do
      project = create(:project, organization: org)

      get member_projects_path

      card = Capybara.string(response.body).find("[data-test='project-card-#{project.id}']")
      expect(card.find("[data-test='project-health-errors']")).to have_text(I18n.t("member.projects.card.no_errors"))
      expect(card).to have_no_css("[data-test='project-health-uptime']")
      expect(card).to have_no_css("[data-test='project-health-release']")
    end

    it "keeps the open-project hint hidden until the card is hovered or focused" do
      project = create(:project, organization: org)

      get member_projects_path

      card = Capybara.string(response.body).find("[data-test='project-card-#{project.id}']")
      hint = card.find("[data-test='project-open-hint']", visible: :all)
      expect(hint).to have_text(I18n.t("member.projects.card.open"))
      expect(hint[:class].split).to include("hidden", "group-hover/card:inline", "group-focus-visible/card:inline")
    end

    it "filters the cards by group" do
      chosen = create(:group, organization: org, name: "Chosen")
      other = create(:group, organization: org, name: "Other")
      inside = create(:project, organization: org, group: chosen, name: "InsideXYZ")
      outside = create(:project, organization: org, group: other, name: "OutsideXYZ")

      get member_projects_path, params: { group_id: [ chosen.id ] }

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='project-card-#{inside.id}']")
      expect(html).to have_no_css("[data-test='project-card-#{outside.id}']")
      expect(html).to have_no_css("[data-test='projects-empty-groups']")
    end

    # F016 — "With problems" keeps the projects a card paints red: open errors or a monitor that is down.
    it "filters the cards on the projects with problems" do
      failing = create(:project, organization: org, name: "FailingXYZ")
      create(:error_group, project: failing)
      down = create(:project, organization: org, name: "DownXYZ")
      down.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
      create(:uptime_monitor, project: down, current_status: :down)
      healthy = create(:project, organization: org, name: "HealthyXYZ")

      get member_projects_path, params: { health: "problems" }

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='filter-health']")
      expect(html).to have_css("[data-test='project-card-#{failing.id}']")
      expect(html).to have_css("[data-test='project-card-#{down.id}']")
      expect(html).to have_no_css("[data-test='project-card-#{healthy.id}']")
    end

    it "says no project matches when the chosen group has none" do
      empty = create(:group, organization: org)
      create(:project, organization: org)

      get member_projects_path, params: { group_id: [ empty.id ] }

      expect(response.body).to include('data-test="projects-no-match"')
      expect(response.body).not_to include('data-test="projects-empty"')
    end

    it "sorts the cards by open errors from the View menu" do
      calm = create(:project, organization: org, name: "Aaa calm")
      busy = create(:project, organization: org, name: "Zzz busy")
      create_list(:error_group, 3, project: busy)
      create(:error_group, project: calm)

      get member_projects_path, params: { sort: "-errors" }

      ids = Capybara.string(response.body).all("a[data-test^='project-card-']").map { |a| a["data-test"] }
      expect(ids).to eq([ "project-card-#{busy.id}", "project-card-#{calm.id}" ])
      expect(Capybara.string(response.body).find("a[data-test='projects-sort--errors']", visible: :all)["aria-current"]).to eq("true")
    end

    it "sorts the cards by latest release" do
      old = create(:project, organization: org, name: "Aaa old")
      fresh = create(:project, organization: org, name: "Zzz fresh")
      create(:release, project: old, created_at: 5.days.ago)
      create(:release, project: fresh, created_at: 1.hour.ago)

      get member_projects_path, params: { sort: "-release" }

      ids = Capybara.string(response.body).all("a[data-test^='project-card-']").map { |a| a["data-test"] }
      expect(ids).to eq([ "project-card-#{fresh.id}", "project-card-#{old.id}" ])
    end

    it "no longer shows the counters row in the header" do
      create(:project, organization: org)

      get member_projects_path

      expect(response.body).not_to include('data-test="projects-counts"')
    end
  end

  # The page of cards (D19–D24): one component for the bar, the groups, Show more and the sections to set up.
  describe "GET index — card page" do
    before { sign_in(owner) }

    def html = Capybara.string(response.body)

    it "is one panel holding the toolbar and the cards (T1, D19)" do
      project = create(:project, organization: org)

      get member_projects_path

      panel = html.find("div.rounded-lg.bg-white[data-test='projects-cards']")
      expect(panel).to have_css("[data-test='projects-toolbar']")
      expect(panel).to have_css("[data-test='project-card-#{project.id}']")
    end

    it "offers By group and None in the View menu, by group by default (D20)" do
      group = create(:group, organization: org)
      create(:project, organization: org, group:)

      get member_projects_path

      expect(html).to have_css("[data-test='projects-group-by-group']", visible: :all)
      expect(html).to have_css("[data-test='projects-group-by-none']", visible: :all)
      expect(html).to have_css("section[data-test='projects-group-#{group.id}'] h2")
    end

    it "drops the group headings when grouping is None (D20)" do
      group = create(:group, organization: org)
      project = create(:project, organization: org, group:)

      get member_projects_path, params: { grouped: "none" }

      expect(html).to have_no_css("section[data-test='projects-group-#{group.id}']")
      expect(html).to have_css("section[data-test='projects-all'] [data-test='project-card-#{project.id}']")
      expect(html).to have_no_css("section[data-test='projects-all'] h2")
    end

    it "shows 12 cards, then Show more adds the next 12 keeping the filters (D23)" do
      create_list(:project, 13, organization: org)

      get member_projects_path, params: { q: "", grouped: "none" }

      expect(html).to have_css("[data-test^='project-card-']", count: 12)
      more = html.find("[data-test='projects-more']")
      expect(more[:href]).to include("limit=24", "grouped=none")
      expect(more.text.strip).to eq(I18n.t("ui.card_grid.show_more_count", count: 1))

      get more[:href]

      expect(Capybara.string(response.body)).to have_css("[data-test^='project-card-']", count: 13)
      expect(Capybara.string(response.body)).to have_no_css("[data-test='projects-more']")
    end

    it "draws the card states as badges with a dot (D22)" do
      project = create(:project, organization: org)

      get member_projects_path

      errors = html.find("[data-test='project-card-#{project.id}'] [data-test='project-health-errors']")
      expect(errors).to have_css("span.rounded-full")
    end

    it "says no project matches with a way to clear the filters (G4, G13)" do
      create(:project, organization: org)

      get member_projects_path, params: { q: "nothing-like-this" }

      expect(html).to have_css("[data-test='projects-no-match']")
      expect(html).to have_css("[data-test='projects-reset-filters']")
    end

    it "lists empty groups at the bottom as dashed sections to set up (D11)" do
      empty = create(:group, organization: org, name: "Mobile")
      create(:project, organization: org)

      get member_projects_path

      expect(html).to have_css("[data-test='projects-empty-groups'] .border-dashed[data-test='projects-empty-group-#{empty.id}']", text: "Mobile")
    end
  end

  describe "GET index — filtro piattaforma" do
    before { sign_in(owner) }

    it "mostra solo i progetti che dichiarano la piattaforma" do
      plat = create(:platform, organization: org)
      with_plat = create(:project, organization: org, name: "HasPlatformXYZ")
      with_plat.platforms << plat
      create(:project, organization: org, name: "NoPlatformXYZ")
      get member_projects_path, params: { platform_id: [ plat.id ] }
      expect(response.body).to include("HasPlatformXYZ")
      expect(response.body).not_to include("NoPlatformXYZ")
    end

    it "progetto con 2 piattaforme filtrate compare una sola volta (distinct)" do
      p1 = create(:platform, organization: org)
      p2 = create(:platform, organization: org)
      proj = create(:project, organization: org, name: "ZmultidistinctXYZ")
      proj.platforms << [ p1, p2 ]
      get member_projects_path, params: { platform_id: [ p1.id, p2.id ] }
      expect(response.body.scan("ZmultidistinctXYZ").size).to eq(1)
    end

    it "filtro piattaforma senza match → box no-match" do
      plat = create(:platform, organization: org)
      create(:project, organization: org, name: "Lonely")
      get member_projects_path, params: { platform_id: [ plat.id ] }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("projects-no-match")
    end
  end

  # CYRA-883: the project page header reads like the list pages. Actions sit on the title row, the
  # description is the subtitle, the ticket key appears once next to the name. On the overview the
  # ticket counts move to the Tickets list title; the other tabs have no list, so they keep them on top.
  describe "GET show — header (CYRA-883)" do
    let(:project) { create(:project, organization: org, description: "Payments backend") }

    before { sign_in(owner) }

    it "puts the actions on the title row, next to the name" do
      get member_project_path(project)

      title_row = Capybara.string(response.body).find("[data-test='project-title-row']")
      expect(title_row).to have_css("h1", text: project.name)
      expect(title_row).to have_css("[data-test='project-actions'] [data-test='project-new-ticket']")
      expect(title_row).to have_css("[data-test='project-actions'] [data-test='project-new-idea']")
      expect(title_row).to have_css("[data-test='project-actions'] [data-test='project-edit']")
    end

    it "shows the description as the subtitle and the key once, next to the name" do
      get member_project_path(project)

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='project-title-row'] [data-test='project-subtitle']", text: "Payments backend")
      expect(html).to have_css("[data-test='project-title-row'] [data-test='project-ticket-key']", text: project.key)
      expect(html).to have_css("[data-test='project-ticket-key']", count: 1)
      expect(html).to have_css("[data-test='project-subtitle']", count: 1)
    end

    it "moves the ticket counts to the Tickets list title on the overview" do
      get member_project_path(project)

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='project-tickets'] [data-test='project-counts']")
      expect(html).not_to have_css("[data-test='project-title-row'] [data-test='project-counts']")
      expect(html).to have_css("[data-test='project-counts']", count: 1)
    end

    it "keeps the counts in the header on the other tabs, where there is no ticket list" do
      get member_project_settings_path(project)

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='project-counts'] [data-test='project-count-todo']")
      expect(html).to have_css("[data-test='project-title-row'] [data-test='project-actions'] [data-test='project-new-ticket']")
    end

    it "links the to-do and in-progress counts to the ticket list filtered on those statuses" do
      s = {
        todo: create(:ticket_status, organization: org, code: "open", category: :open, position: 0),
        in_progress: create(:ticket_status, organization: org, code: "in_progress", category: :in_progress, position: 1),
        in_review: create(:ticket_status, organization: org, code: "in_review", category: :in_progress, position: 2)
      }
      create(:ticket, project:, organization: org, status: s[:todo])

      get member_project_path(project)

      html = Capybara.string(response.body)
      todo = html.find("a[data-test='project-count-todo']")
      expect(todo[:href]).to include("status_id").and include(s[:todo].id)
      expect(todo[:href]).not_to include(s[:in_progress].id)
      in_progress = html.find("a[data-test='project-count-in-progress']")
      expect(in_progress[:href]).to include(s[:in_progress].id).and include(s[:in_review].id)
    end
  end

  describe "GET show — tabs (CYRA-883)" do
    let(:project) { create(:project, organization: org) }

    before { sign_in(owner) }

    it "keeps five tabs in view and the less used ones in the More menu" do
      get member_project_path(project)

      nav = Capybara.string(response.body).find("[data-test='project-tabs']")
      %w[project-tab-overview project-milestones-link project-documents-link project-environments-link].each do |id|
        expect(nav).to have_css("[data-test='#{id}']")
        expect(nav).not_to have_css("[data-test='project-tab-more-menu'] [data-test='#{id}']")
      end
      %w[project-secrets-link project-usage-link project-guidance-link project-settings-link].each do |id|
        expect(nav).to have_css("[data-test='project-tab-more-menu'] [data-test='#{id}']", visible: :all)
      end
    end

    it "names the active tab on the More trigger when it lives in the menu" do
      get member_project_settings_path(project)

      trigger = Capybara.string(response.body).find("[data-test='project-tab-more']")
      expect(trigger).to have_text(I18n.t("member.projects.show.tab_settings"))
      expect(trigger["aria-current"]).to eq("page")
    end

    it "labels the trigger More when the active tab is in view" do
      get member_project_path(project)

      trigger = Capybara.string(response.body).find("[data-test='project-tab-more']")
      expect(trigger).to have_text(I18n.t("ui.page_header.more"))
      expect(trigger["aria-current"]).to be_nil
    end
  end

  describe "GET show — layout (CYRA-883)" do
    let(:project) { create(:project, organization: org) }

    before { sign_in(owner) }

    it "shows the last release in the health band" do
      create(:release, project:, version: "2.4.0", environment: "production")

      get member_project_path(project)

      cell = Capybara.string(response.body).find("[data-test='health-release']")
      expect(cell).to have_text("2.4.0").and have_text("production")
    end

    it "leaves the release cell out when the project has no release" do
      get member_project_path(project)

      expect(response.body).not_to include('data-test="health-release"')
    end

    it "groups availability and monitoring tools in one Monitoring section" do
      project.platforms << create(:platform, :uptime_capable, organization: org)
      project.environments << create(:environment, organization: org)

      get member_project_path(project)

      section = Capybara.string(response.body).find("[data-test='project-monitoring']")
      expect(section).to have_css("[data-test='project-uptime']")
      expect(section).to have_css("[data-test='project-tools']")
    end

    it "orders the right column: information, monitoring, releases" do
      create(:release, project:, version: "1.0.0", environment: "production")

      get member_project_path(project)

      body = response.body
      expect(body.index('data-test="project-about"')).to be < body.index('data-test="project-monitoring"')
      expect(body.index('data-test="project-monitoring"')).to be < body.index('data-test="project-releases"')
    end

    it "keeps the information panel closed until the reader opens it" do
      get member_project_path(project)

      html = Capybara.string(response.body)
      expect(html).to have_css("details[data-test='project-about']:not([open]) > summary", text: "About this project")
    end

    it "shows the last three releases and opens the rest from See all" do
      5.times { |i| create(:release, project:, version: "1.0.#{i}", environment: "production", created_at: i.minutes.ago) }

      get member_project_path(project)

      panel = Capybara.string(response.body).find("[data-test='project-releases']")
      expect(panel).to have_css("[data-test='project-release-row']", count: 3)
      expect(panel).to have_css("button[data-test='project-releases-all']", text: "See all")
      expect(panel).to have_css("dialog[data-test='project-releases-modal'] [data-test='project-release-all-row']", count: 5, visible: :all)
    end

    it "opens all releases in the standard modal shell, with one Close in the header (F24)" do
      5.times { |i| create(:release, project:, version: "1.0.#{i}", environment: "production", created_at: i.minutes.ago) }

      get member_project_path(project)

      dialog = Nokogiri::HTML(response.body).at_css("dialog[data-test='project-releases-modal']")
      expect(dialog["class"]).to include("dark:bg-zinc-950")
      expect(dialog.at_css("header [data-test='project-releases-close']")).to be_present
      expect(dialog.css("[data-action~='ui--dialog#close']").size).to eq(1)
      expect(dialog.at_css("[data-test='project-releases-modal-panel'] [data-test='project-releases-count']")).to be_present
    end

    it "has no See all when the releases fit the panel" do
      create(:release, project:, version: "1.0.0", environment: "production")

      get member_project_path(project)

      expect(response.body).not_to include("project-releases-all")
    end

    it "closes the page with created, updated and the history button, in a panel of their own (E22)" do
      get member_project_path(project)

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='project-page-footer'] [data-test='project-audit']")
      expect(html).to have_css("[data-test='project-page-footer'] button[data-test='project-history']")
      expect(html).to have_css("[data-test='project-page-footer'] [data-test='activity-modal']", visible: :all)
      expect(html).to have_no_css("[data-test='project-about'] [data-test='project-audit']")
      expect(response.body.index('data-test="project-about"')).to be < response.body.index('data-test="project-page-footer"')
    end
  end

  describe "GET show — fascia salute" do
    let(:project) { create(:project, organization: org) }

    before { sign_in(owner) }

    it "mostra la fascia salute con errori aperti, log 7g e ticket aperti" do
      create(:error_group, project:, status: :unresolved)
      create(:error_group, project:, status: :resolved)
      create(:log_entry, project:, occurred_at: 1.day.ago)
      create(:ticket, project:, organization: org)

      get member_project_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("project-health")
      expect(response.body).to include("health-errors")
      expect(response.body).to include("health-logs")
      expect(response.body).to include("health-tickets")
    end

    it "top slow query nella fascia (kind slow_query, ordinate per durata media)" do
      slow = create(:metric_group, project:, kind: :slow_query, title: "SELECT enorme",
                    samples_count: 2, duration_total_ms: 4000)

      get member_project_path(project)

      expect(response.body).to include("health-slow-queries")
      expect(response.body).to include("SELECT enorme")
    end

    # CYRA-15: nella card "Query più lente" ogni voce era testo semplice; deve essere
    # un link alla show della metrica performance corrispondente.
    it "ogni voce slow query è un link alla show metrica corrispondente (CYRA-15)" do
      slow = create(:metric_group, project:, kind: :slow_query, title: "SELECT enorme",
                    samples_count: 2, duration_total_ms: 4000)

      get member_project_path(project)

      expect(response.body).to include(%(href="#{member_monitoring_metric_group_path(slow)}"))
    end

    # CYRA-16/CYRA-358: la card "Non chiusi" è un link alla lista ticket filtrata su TUTTI gli status
    # non conclusi (categoria da fare + in corso), quindi anche "in revisione" — che il vecchio filtro
    # per code [open, in_progress] saltava. Il link porta esattamente all'insieme che il riquadro conta.
    it "la card 'Non chiusi' è un link alla lista filtrata sugli status non conclusi (CYRA-358)" do
      open_status = create(:ticket_status, organization: org, code: "open", label: "Open", category: :open, position: 0)
      in_progress = create(:ticket_status, organization: org, code: "in_progress", label: "In Progress", category: :in_progress, position: 1)
      in_review = create(:ticket_status, organization: org, code: "in_review", label: "In Review", category: :in_progress, position: 2)
      create(:ticket_status, organization: org, code: "closed", label: "Closed", category: :done, position: 3)
      create(:ticket, project:, organization: org, status: open_status)

      get member_project_path(project)

      link = Capybara.string(response.body).find("a[data-test='health-tickets']")
      expect(link[:href]).to eq(
        list_member_tickets_path(project_id: [ project.id ], status_id: [ open_status.id, in_progress.id, in_review.id ])
      )
    end

    # CYRA-358: gli status conclusi (categoria done) restano fuori dal link "Non chiusi".
    it "il link 'Non chiusi' esclude gli status conclusi (CYRA-358)" do
      open_status = create(:ticket_status, organization: org, code: "open", label: "Open", category: :open, position: 0)
      create(:ticket_status, organization: org, code: "resolved", label: "Resolved", category: :done, position: 3)

      get member_project_path(project)

      link = Capybara.string(response.body).find("a[data-test='health-tickets']")
      expect(link[:href]).to eq(
        list_member_tickets_path(project_id: [ project.id ], status_id: [ open_status.id ])
      )
    end
  end

  # CYRA-358: "aperti" mostrava tre numeri diversi per lo stesso progetto (pill header, KPI card, card
  # in lista). Ora l'insieme è definito una volta sola per CATEGORIA: Da fare / In corso / Non chiusi.
  describe "GET show — conteggi coerenti dei ticket (CYRA-358)" do
    let(:project) { create(:project, organization: org) }

    before { sign_in(owner) }

    def install_statuses
      {
        todo: create(:ticket_status, organization: org, code: "open", label: "Open", category: :open, position: 0),
        in_progress: create(:ticket_status, organization: org, code: "in_progress", label: "In Progress", category: :in_progress, position: 1),
        in_review: create(:ticket_status, organization: org, code: "in_review", label: "In Review", category: :in_progress, position: 2),
        resolved: create(:ticket_status, organization: org, code: "resolved", label: "Resolved", category: :done, position: 3),
        closed: create(:ticket_status, organization: org, code: "closed", label: "Closed", category: :done, position: 4)
      }
    end

    it "la pill 'In corso' somma in lavorazione e in revisione, 'Conclusi' somma risolti e chiusi" do
      s = install_statuses
      # fixture bulk nel setup (non è un N+1 di produzione): creare più ticket ripete i lookup del
      # factory (agent_workflow) e le validazioni tenant.
      allow_n_plus_one do
        2.times { create(:ticket, project:, organization: org, status: s[:todo]) }
        create(:ticket, project:, organization: org, status: s[:in_progress])
        create(:ticket, project:, organization: org, status: s[:in_review])
        3.times { create(:ticket, project:, organization: org, status: s[:resolved]) }
        create(:ticket, project:, organization: org, status: s[:closed])
      end

      get member_project_path(project)

      html = Capybara.string(response.body)
      expect(html.find("[data-test='project-count-todo']")).to have_text("2")
      expect(html.find("[data-test='project-count-in-progress']")).to have_text("2") # in_progress + in_review
      expect(html.find("[data-test='project-count-done']")).to have_text("4")        # resolved + closed
      expect(html.find("[data-test='project-count-total']")).to have_text("8")
    end

    it "la KPI 'Non chiusi' vale da fare + in corso (incluso in revisione), non i conclusi" do
      s = install_statuses
      allow_n_plus_one do # fixture bulk nel setup (vedi sopra), non un N+1 di produzione
        2.times { create(:ticket, project:, organization: org, status: s[:todo]) }
        create(:ticket, project:, organization: org, status: s[:in_progress])
        create(:ticket, project:, organization: org, status: s[:in_review])
        create(:ticket, project:, organization: org, status: s[:resolved])
        create(:ticket, project:, organization: org, status: s[:closed])
      end

      get member_project_path(project)

      card = Capybara.string(response.body).find("a[data-test='health-tickets']")
      expect(card).to have_text(I18n.t("member.projects.health.tickets_unresolved"))
      expect(card.text).to match(/\b4\b/) # todo(2) + in_progress(1) + in_review(1)
    end

    # Scenario 1 del ticket: la stessa parola non indica mai due insiemi diversi nella stessa schermata.
    it "non chiama più 'aperti' nessun conteggio e usa etichette distinte in cima e nel riquadro" do
      install_statuses
      create(:ticket, project:, organization: org)

      get member_project_path(project)

      html = Capybara.string(response.body)
      counts = html.find("[data-test='project-counts']")
      expect(counts).to have_text(I18n.t("member.projects.show.stat_todo"))
      expect(counts).not_to have_text(/aperti/i)
      card = html.find("a[data-test='health-tickets']")
      expect(card).not_to have_text(/aperti/i)
      # etichetta in cima (Da fare) ≠ etichetta del riquadro (Non chiusi)
      expect(I18n.t("member.projects.show.stat_todo")).not_to eq(I18n.t("member.projects.health.tickets_unresolved"))
    end
  end

  # Scenario 2 del ticket: il numero dei ticket "da fare" è identico tra lista e dettaglio.
  describe "GET — coerenza lista/dettaglio del conteggio Da fare (CYRA-358)" do
    before { sign_in(owner) }

    it "la card in lista e la pill nella pagina mostrano lo stesso numero Da fare" do
      project = create(:project, organization: org, name: "CoerenzaXYZ")
      todo = create(:ticket_status, organization: org, code: "open", label: "Open", category: :open, position: 0)
      in_progress = create(:ticket_status, organization: org, code: "in_progress", label: "In Progress", category: :in_progress, position: 1)
      allow_n_plus_one do # fixture bulk nel setup (vedi sopra), non un N+1 di produzione
        3.times { create(:ticket, project:, organization: org, status: todo) }
        2.times { create(:ticket, project:, organization: org, status: in_progress) }
      end

      # The card no longer shows the to-do count: the table view carries it.
      owner.update!(projects_view: "table")
      get member_projects_path
      card = Capybara.string(response.body).find("[data-test='project-row-todo-#{project.id}']")
      expect(card).to have_text("3")

      get member_project_path(project)
      pill = Capybara.string(response.body).find("[data-test='project-count-todo']")
      expect(pill).to have_text("3")
    end
  end

  describe "GET show — card release (CYRA-9)" do
    let(:project) { create(:project, organization: org) }

    before { sign_in(owner) }

    it "una release con version = commit SHA a 40 char è mostrata accorciata, mai grezza" do
      sha40 = "cf4657cc8b5a2f1e9d3c7b0a6e4d2f8c1b9a0e7d"
      create(:release, project:, version: sha40, environment: "production")

      get member_project_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("project-releases")
      expect(response.body).not_to include(sha40)
      expect(response.body).to include(sha40.first(7))
    end

    it "una release con tag di versione reale resta invariata" do
      create(:release, project:, version: "v1.2.3", environment: "production")

      get member_project_path(project)

      expect(response.body).to include("v1.2.3")
    end
  end

  describe "GET show — filtri lista ticket" do
    let(:project) { create(:project, organization: org) }

    before { sign_in(owner) }

    it "mostra la graffetta solo per i ticket con allegati" do
      attached = create(:ticket, organization: org, project: project)
      attached.files.attach(fixture_file_upload("notes.txt", "text/plain"))
      plain = create(:ticket, organization: org, project: project)

      get member_project_path(project)

      expect(response.body).to include("ticket-attachments-indicator-#{attached.id}")
      expect(response.body).not_to include("ticket-attachments-indicator-#{plain.id}")
    end

    it "mostra l'icona robot del gate agenti su ogni riga ticket" do
      workable = create(:ticket, organization: org, project: project, agent_eligibility: :allowed)
      blocked = create(:ticket, organization: org, project: project, agent_eligibility: :blocked)

      get member_project_path(project)

      expect(response.body).to include("ticket-agent-indicator-#{workable.id}")
      expect(response.body).to include("ticket-agent-indicator-#{blocked.id}")
      expect(response.body).to include("text-emerald-600", "text-gray-300")
    end

    it "filtra per status" do
      open_status = create(:ticket_status, organization: org, code: "open", label: "Open")
      done_status = create(:ticket_status, organization: org, code: "done", label: "Done")
      ticket_open = create(:ticket, organization: org, project: project, status: open_status)
      ticket_done = create(:ticket, organization: org, project: project, status: done_status)
      get member_project_path(project), params: { status_id: [ open_status.id ] }
      expect(response.body).to include(ticket_open.code)
      expect(response.body).not_to include(ticket_done.code)
    end

    it "filtra per priority" do
      high = create(:ticket_priority, organization: org, code: "high", label: "High")
      low = create(:ticket_priority, organization: org, code: "low", label: "Low")
      ticket_high = create(:ticket, organization: org, project: project, priority: high)
      ticket_low = create(:ticket, organization: org, project: project, priority: low)
      get member_project_path(project), params: { priority_id: [ high.id ] }
      expect(response.body).to include(ticket_high.code)
      expect(response.body).not_to include(ticket_low.code)
    end

    it "filtra per assignee" do
      assignee = create(:account)
      create(:membership, account: assignee, organization: org, role: :member)
      ticket_assigned = create(:ticket, organization: org, project: project, assignee: assignee)
      ticket_unassigned = create(:ticket, organization: org, project: project)
      get member_project_path(project), params: { assignee_id: [ assignee.id ] }
      expect(response.body).to include(ticket_assigned.code)
      expect(response.body).not_to include(ticket_unassigned.code)
    end

    it "search per titolo" do
      ticket_match = create(:ticket, organization: org, project: project, title: "SpecialBugTitle")
      ticket_other = create(:ticket, organization: org, project: project, title: "MundaneStuff")
      get member_project_path(project), params: { q: "SpecialBug" }
      expect(response.body).to include(ticket_match.code)
      expect(response.body).not_to include(ticket_other.code)
    end

    it "filtro senza match → no-match + toolbar (stats sul totale, non first-run)" do
      status = create(:ticket_status, organization: org, code: "open")
      other = create(:ticket_status, organization: org, code: "closed")
      create(:ticket, organization: org, project: project, status: status)
      get member_project_path(project), params: { status_id: [ other.id ] }
      expect(response.body).to include("project-tickets-no-match")
      expect(response.body).to include("project-tickets-toolbar")
    end

    # T1 — nothing outside panels: the title and its counts head the panel of the list.
    it "puts the Tickets title and counts inside the list panel, with or without tickets" do
      get member_project_path(project)
      empty = Nokogiri::HTML(response.body).at_css("[data-test='project-tickets-panel']")
      expect(empty.at_css("[data-test='project-tickets-title']")).to be_present
      expect(empty.at_css("[data-test='project-tickets-empty']")).to be_present

      create(:ticket, organization: org, project: project)
      get member_project_path(project)
      panel = Nokogiri::HTML(response.body).at_css("[data-test='project-tickets-panel']")
      expect(panel.at_css("[data-test='project-counts']")).to be_present
      expect(panel.at_css("[data-test='project-tickets-toolbar']")).to be_present
    end

    it "il titolo Tickets è sopra/fuori la barra filtri (ordine DOM)" do
      create(:ticket, organization: org, project: project)
      get member_project_path(project)
      expect(response.body.index("project-tickets-title"))
        .to be < response.body.index("project-tickets-toolbar")
    end
  end

  describe "GET show — book collegati" do
    let(:project) { create(:project, organization: org) }

    before { sign_in(owner) }

    it "mostra i book collegati direttamente" do
      book = create(:knowledge_book, organization: org, project: project, title: "Manuale condiviso")

      get member_project_path(project)

      expect(response.body).to include('data-test="project-books"')
      expect(response.body).to include(book.title)
    end

    it "mostra i book collegati al gruppo del progetto" do
      group = create(:group, organization: org)
      project.update!(group: group)
      book = create(:knowledge_book, organization: org, project: create(:project, organization: org))
      book.groups << group

      get member_project_path(project)

      expect(response.body).to include(book.title)
    end
  end

  # CYRA-12: la card ticket della show progetto era illimitata (scope.to_a). Va paginata a max 15.
  describe "GET show — paginazione lista ticket (CYRA-12)" do
    let(:project) { create(:project, organization: org) }

    before { sign_in(owner) }

    def ticket_rows(body) = body.scan('data-test="project-ticket-row"').size

    # Fixture bulk: ogni create fa assign_number (lock progetto) + validazione tenant (member_of?),
    # una query per record → N+1 di SETUP, non del path show sotto misura (allow_n_plus_one puntuale).
    def create_tickets(count, **attrs)
      allow_n_plus_one { create_list(:ticket, count, organization: org, project: project, **attrs) }
    end

    it "mostra al massimo 15 ticket per pagina con il pager quando il progetto ha più di 15 ticket" do
      create_tickets(18)
      get member_project_path(project)
      expect(response).to have_http_status(:ok)
      expect(ticket_rows(response.body)).to eq(15)
      expect(response.body).to include('data-test="project-tickets-pagination"')
      expect(response.body).to include('data-test="pagination-next"')
    end

    # CYRA-924 — no count in the bar (C63): the pager says how many tickets the filter finds.
    it "the pager counts every ticket, not the page size, and the bar holds no count" do
      create_tickets(18)
      get member_project_path(project)
      expect(response.body).to include(I18n.t("pagination.info", from: 1, to: 15, total: 18))
      toolbar = Nokogiri::HTML(response.body).at_css("[data-test='project-tickets-toolbar']")
      expect(toolbar.text).not_to include(I18n.t("member.projects.show.tickets_count", count: 18))
    end

    it "la seconda pagina mostra i ticket restanti" do
      create_tickets(18)
      get member_project_path(project), params: { page: 1 }
      page1 = response.body
      expect(ticket_rows(page1)).to eq(15)
      get member_project_path(project), params: { page: 2 }
      expect(response).to have_http_status(:ok)
      expect(ticket_rows(response.body)).to eq(3)
      expect(response.body).not_to eq(page1)
    end

    it "i filtri della toolbar sono preservati nei link di paginazione" do
      open_status = create(:ticket_status, organization: org, code: "open", label: "Open")
      other_status = create(:ticket_status, organization: org, code: "closed", label: "Closed")
      create_tickets(18, status: open_status)
      excluded = create(:ticket, organization: org, project: project, status: other_status)

      get member_project_path(project), params: { status_id: [ open_status.id ] }

      expect(ticket_rows(response.body)).to eq(15)
      expect(response.body).not_to include(excluded.code)
      next_link = response.body[/<a[^>]*data-test="pagination-next"[^>]*>/]
      expect(next_link).to be_present
      expect(next_link).to include("page=2")
      expect(next_link).to include(open_status.id)
    end

    it "con esattamente 15 ticket non mostra il controllo pagina successiva" do
      create_tickets(15)
      get member_project_path(project)
      expect(ticket_rows(response.body)).to eq(15)
      expect(response.body).not_to include('data-test="pagination-next"')
    end

    it "con 16 ticket compare il controllo pagina successiva" do
      create_tickets(16)
      get member_project_path(project)
      expect(ticket_rows(response.body)).to eq(15)
      expect(response.body).to include('data-test="pagination-next"')
    end
  end

  describe "scoping per ruolo" do
    it "god vede ogni progetto dell'org senza assegnazione (unscoped)" do
      god = create(:account, god: true)
      create(:membership, account: god, organization: org, role: :member)
      sign_in(god)
      project = create(:project, organization: org)
      get member_project_path(project)
      expect(response).to have_http_status(:ok)
    end

    it "god SENZA membership che entra in un'org vede TUTTI i suoi progetti (non quelli di altre org)" do
      god = create(:account, god: true)
      org_x = create(:organization, name: "GodOrgX")
      org_y = create(:organization, name: "GodOrgY")
      create(:project, organization: org_x, name: "XAlphaProj")
      create(:project, organization: org_x, name: "XBetaProj")
      create(:project, organization: org_y, name: "YGammaProj")
      sign_in(god)
      post member_organization_switches_path, params: { organization_id: org_x.id }
      get member_projects_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("XAlphaProj").and include("XBetaProj")
      expect(response.body).not_to include("YGammaProj")
    end
  end
  # CYRA-367 — il riquadro delle operazioni più lente mostrava SQL grezzo tagliato a metà, righe su
  # tabelle del framework e tempi da dieci minuti presentati come fatti.
  describe "GET show (operazioni più lente)" do
    let(:project) { create(:project, organization: org) }

    def slow_query(title:, avg_ms:, samples: 10)
      create(:metric_group, project:, kind: :slow_query, title:,
                            samples_count: samples, duration_total_ms: avg_ms * samples)
    end

    it "non mostra le tabelle interne del sistema, e dichiara quante ne ha tolte" do
      allow_n_plus_one do
        slow_query(title: 'INSERT INTO "solid_queue_jobs" ("queue_name") VALUES (?)', avg_ms: 900)
        slow_query(title: 'SELECT * FROM "solid_cache_entries" WHERE ?', avg_ms: 800)
        slow_query(title: 'SELECT "ticketing_tickets".* FROM "ticketing_tickets" WHERE ?', avg_ms: 300)
      end
      sign_in(owner)

      get member_project_path(project)

      panel = Nokogiri::HTML(response.body).at_css('[data-test="health-slow-queries"]').text
      expect(panel).not_to include("solid_queue_jobs", "solid_cache_entries")
      expect(response.body).to include('data-test="health-slow-queries-excluded"')
      expect(panel).to include(I18n.t("metrics.slow_queries.excluded", count: 2))
    end

    it "scrive la riga in forma leggibile, non lo SQL" do
      slow_query(title: 'SELECT "ticketing_tickets".* FROM "ticketing_tickets" WHERE ?', avg_ms: 4500)
      sign_in(owner)

      get member_project_path(project)

      panel = Nokogiri::HTML(response.body).at_css('[data-test="health-slow-queries"]').text
      expect(panel).to include("ticketing tickets")
      expect(panel).not_to include("SELECT")
    end

    it "segnala come sospetto un valore fuori scala, invece di darlo per certo" do
      slow_query(title: 'INSERT INTO "ticketing_events" VALUES (?)', avg_ms: 616_167)
      sign_in(owner)

      get member_project_path(project)

      expect(response.body).to include('data-test="health-slow-query-suspect"')
      expect(response.body).to include(I18n.t("metrics.slow_queries.suspect"))
    end

    it "un valore normale non porta l'avviso" do
      slow_query(title: 'SELECT * FROM "ticketing_tickets" WHERE ?', avg_ms: 4500)
      sign_in(owner)

      get member_project_path(project)

      expect(response.body).not_to include('data-test="health-slow-query-suspect"')
    end
  end
end
