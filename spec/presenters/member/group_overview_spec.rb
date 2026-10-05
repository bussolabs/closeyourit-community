# frozen_string_literal: true

require "rails_helper"

# CYRA-334 — i conteggi che ogni panoramica mostra in cima. Qui si verifica che ogni gruppo abbia i
# suoi numeri e che quelli senza (l'automazione ha già le sue schede, il vault la sua pagina) non ne
# inventino: meglio nessun numero che un numero senza significato.
RSpec.describe Member::GroupOverview do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def counts_for(group_id, con_seo: true)
    progetti = Projects::Project.where(organization_id: organization.id)
    siti = Seo::Site.where(project_id: progetti.select(:id))
    described_class.new(
      group: Navigation::Group.find(group_id), organization:,
      visible_projects: progetti,
      visible_tickets: Ticketing::Ticket.where(project_id: progetti.select(:id)),
      visible_ideas: Ideas::Idea.where(project_id: progetti.select(:id)),
      visible_seo_issues: (Seo::Issue.where(site_id: siti.select(:id)) if con_seo),
      visible_seo_sites: (siti if con_seo)
    ).counts
  end

  before { Types::InstallDefaults.call(organization:) }

  it "l'osservabilità conta gli errori non risolti e i controlli non raggiungibili" do
    create(:error_group, project:, status: :unresolved)

    chiavi = counts_for("observability").to_h { |count| [ count.key, count.value ] }

    expect(chiavi["errors"]).to eq(1)
    expect(chiavi).to have_key("monitors_down")
    expect(chiavi).to have_key("monitors")
  end

  it "l'infrastruttura conta le macchine e quelle non raggiungibili" do
    create(:server_host, organization:, status: :down)

    chiavi = counts_for("infrastructure").to_h { |count| [ count.key, count.value ] }

    expect(chiavi["servers"]).to eq(1)
    expect(chiavi["servers_down"]).to eq(1)
  end

  # CYRA-521 — progetti e ambienti erano i conteggi dell'area "Applicativi", che conteneva insieme i
  # progetti e il lavoro di prodotto. Ora Progetti è una voce che porta dritto alla sua pagina: non ha
  # una panoramica da riempire, e i suoi numeri li dice la pagina stessa.
  it "il prodotto conta i ticket non conclusi e le idee aperte" do
    aperto = create(:ticket_status, organization:, category: :open)
    concluso = create(:ticket_status, organization:, category: :done)
    create(:ticket, organization:, project:, status: aperto)
    create(:ticket, organization:, project:, status: concluso)
    autore = create(:account)
    create(:membership, account: autore, organization:)
    create(:idea, organization:, project:, author: autore)

    chiavi = counts_for("product").to_h { |count| [ count.key, count.value ] }

    expect(chiavi["tickets_open"]).to eq(1)
    expect(chiavi["ideas_open"]).to eq(1)
  end

  it "le impostazioni contano le persone e i progetti" do
    create(:membership, account: create(:account), organization:)

    chiavi = counts_for("settings").to_h { |count| [ count.key, count.value ] }

    expect(chiavi["members"]).to eq(1)
    expect(chiavi).to have_key("projects")
  end

  # CYRA-556 — il conteggio delle persone comprendeva le utenze usate dai programmi: l'etichetta
  # diceva «Persone» e il numero ne prometteva quattro che non lo sono. Ora sono due numeri distinti.
  it "le impostazioni contano a parte le utenze di servizio" do
    create(:membership, account: create(:account), organization:)
    create(:membership, account: create(:account, :service), organization:)

    chiavi = counts_for("settings").to_h { |count| [ count.key, count.value ] }

    expect(chiavi["members"]).to eq(1)
    expect(chiavi["service_accounts"]).to eq(1)
  end

  # CYRA-535 — l'area SEO apre coi rilievi ancora aperti, non con quanti siti sono dichiarati:
  # dichiarare un sito è configurazione fatta una volta, i rilievi aperti chiedono attenzione adesso.
  it "il SEO conta i rilievi aperti, quelli critici e i siti" do
    environment = create(:environment, organization:)
    project.environments << environment
    project.project_platforms.create!(platform: create(:platform, organization:, supports_analytics: true))
    sito = create(:seo_site, project:, environment:)
    create(:seo_issue, site: sito, severity: :critical)
    create(:seo_issue, site: sito, severity: :low, check_key: "missing_h1")
    create(:seo_issue, site: sito, severity: :high, check_key: "thin_content", status: :resolved)

    chiavi = counts_for("seo").to_h { |count| [ count.key, count.value ] }

    expect(chiavi["seo_issues_open"]).to eq(2)
    expect(chiavi["seo_issues_critical"]).to eq(1)
    expect(chiavi["seo_sites"]).to eq(1)
  end

  # Un chiamante che non passa gli scope del SEO non deve ricevere numeri presi da un'altra sorgente:
  # l'area resta senza conteggi, come quelle che non ne hanno.
  it "senza gli scope visibili del SEO l'area non inventa numeri" do
    expect(counts_for("seo", con_seo: false)).to be_empty
  end

  it "un'area senza conteggi definiti non ne inventa" do
    expect(counts_for("automation")).to be_empty
    expect(counts_for("home")).to be_empty
  end
end
