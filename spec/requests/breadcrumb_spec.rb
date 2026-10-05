# frozen_string_literal: true

# Regressione breadcrumb: la breadcrumb resa nelle pagine reali ha il trail corretto (Home
# root, link intermedi, pagina corrente senza link, profondità contestuale index/show/new/edit),
# è resa nell'header e NON nella topbar, e in area valhalla il root punta a valhalla_root_path.
require "rails_helper"

RSpec.describe "VERIFICA breadcrumb nelle pagine reali", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  # → array di hash { text:, href:, current: } dei crumb resi
  def crumbs(body)
    doc = Nokogiri::HTML(body)
    navs = doc.css("nav[data-test='breadcrumb']")
    # una sola breadcrumb per pagina (quella nell'header; topbar rimossa)
    expect(navs.size).to eq(1), "attese 1 breadcrumb, trovate #{navs.size}"
    navs.first.css("[data-test='breadcrumb-crumb']").map do |el|
      { text: el.text.strip, href: el["href"], current: el["aria-current"] == "page", tag: el.name }
    end
  end

  # B22 — an index trail adds the area level, so it leads somewhere even though its own crumb repeats the title.
  { member_tickets_path: "product", member_monitoring_error_groups_path: "observability" }.each do |index_path, area|
    it "INDEX #{index_path} → Home / area(link) / page(current)" do
      get public_send(index_path)
      c = crumbs(response.body)
      expect(c.map { it[:text] }.first(2)).to eq([ I18n.t("member.nav.home"), I18n.t("member.nav.group_#{area}") ])
      expect(c[1][:href]).to be_present
      expect(c.last[:current]).to be(true)
      expect(c.size).to eq(3)
    end
  end

  # B6 — Projects is an area named like the page: the trail would only repeat the title.
  it "INDEX member_projects_path renders no trail" do
    get member_projects_path
    expect(Nokogiri::HTML(response.body).css("nav[data-test='breadcrumb']")).to be_empty
  end

  it "SHOW ticket → Home / Tickets(link) / <code>(corrente)" do
    get member_ticket_path(ticket)
    c = crumbs(response.body)
    expect(c.first).to include(text: I18n.t("member.nav.home"), href: "/")
    expect(c[2][:href]).to eq(member_tickets_path)  # crump intermedio linka l'index
    expect(c[2][:tag]).to eq("a")
    expect(c.last[:text]).to include(ticket.code)    # leaf = codice ticket
    expect(c.last[:current]).to be(true)
    expect(c.size).to eq(4)
  end

  it "NEW ticket → Home / Tickets(link) / <nuovo>(corrente)" do
    get new_member_ticket_path
    c = crumbs(response.body)
    expect(c.first[:text]).to eq(I18n.t("member.nav.home"))
    expect(c[2][:href]).to eq(member_tickets_path)
    expect(c.last[:current]).to be(true)
    expect(c.last[:href]).to be_nil                  # corrente senza link
    expect(c.size).to eq(4)
  end

  it "EDIT ticket → Home / Tickets(link) / <code>(link) / Modifica(corrente)" do
    get edit_member_ticket_path(ticket)
    c = crumbs(response.body)
    expect(c.first[:text]).to eq(I18n.t("member.nav.home"))
    expect(c[2][:href]).to eq(member_tickets_path)
    expect(c[3][:href]).to eq(member_ticket_path(ticket))  # penultimo linka la show
    expect(c[3][:text]).to include(ticket.code)
    expect(c.last[:current]).to be(true)
    expect(c.size).to eq(5)
  end


  it "EDIT senza show-view (environment) → Home / Environments(link) / <label>(non-link) / Modifica(corrente)" do
    env = create(:environment, organization: org)
    get edit_member_environment_path(env)
    c = crumbs(response.body)
    expect(c.first[:text]).to eq(I18n.t("member.nav.home"))
    expect(c[2][:href]).to eq(member_environments_path)  # risorsa linka il suo index
    expect(c[3][:text]).to eq(env.label)                 # nome item
    expect(c[3][:href]).to be_nil                        # non linkato: la risorsa non ha una show
    expect(c[3][:tag]).to eq("span")
    expect(c.last[:current]).to be(true)                 # "Modifica" = pagina corrente
    expect(c.size).to eq(5)
  end


  it "la topbar NON contiene più una breadcrumb (solo quella dell'header)" do
    get member_ticket_path(ticket)
    # esattamente una nav breadcrumb in tutta la pagina
    expect(response.body.scan(/data-test="breadcrumb"/).size).to eq(1)
  end

  context "area valhalla (god)" do
    let(:god) { create(:account, god: true) }

    # CYRA-170: il god in Valhalla passa dal 2FA (sign_in_god lo attiva al volo + completa il 2° fattore).
    before { sign_in_god(god) }

    it "SHOW valhalla/organizations → la radice linka la root VALHALLA (/valhalla), non /" do
      get valhalla_organization_path(org)
      c = crumbs(response.body)
      expect(c.first[:text]).to eq(I18n.t("member.nav.home"))
      expect(c.first[:href]).to eq(valhalla_root_path)     # root override valhalla
      expect(c.first[:href]).not_to eq("/")
      expect(c.last[:current]).to be(true)
    end
  end

  # CYRA-335 — l'area del percorso viene dalla stessa sorgente che accende la sidebar: se un giorno
  # divergessero, il percorso direbbe un posto e il menu un altro.
  it "l'area del percorso è quella della sidebar, ed è cliccabile" do
    get member_ticket_path(ticket)
    c = crumbs(response.body)

    expect(c[1][:text]).to eq(Navigation::Group.for_controller("member/tickets").label)
    expect(c[1][:tag]).to eq("a")
  end

  # CYRA-658 — la Home non ha più un percorso: mostra una decisione sola e la sua unica briciola
  # ripeteva parola per parola la voce di menu accesa lì accanto. Deroga voluta, presidiata qui.
  it "sulla Home non c'è nessun percorso: sarebbe una briciola sola, uguale al menu" do
    get root_path

    # Non passa da #crumbs, che pretende una breadcrumb: qui il punto è che non ce n'è nessuna.
    expect(Nokogiri::HTML(response.body).css("nav[data-test='breadcrumb']")).to be_empty
  end
end
