# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::ServerDatabases", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:primary) do
    create(:server_host, :up, organization:, name: "db-primary",
           database_snapshot: { "engine" => "postgresql", "reachable" => true, "role" => "primary",
                                "databases" => [ { "name" => "koru_production", "size_bytes" => 800 } ] })
  end
  let!(:staging) do
    create(:server_host, :up, organization:, name: "db-staging",
           database_snapshot: { "engine" => "postgresql", "reachable" => true,
                                "databases" => [ { "name" => "koru_staging", "size_bytes" => 100 } ] })
  end

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "mostra solo i database dell'host aperto" do
    sign_in(owner)
    get member_monitoring_server_path(primary, tab: "hardware")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("koru_production")
    expect(response.body).not_to include("koru_staging")
  end

  # CYRA-474: anche la tab del singolo server ha la colonna variazione a 7 giorni.
  it "la tab del server elenca i database con la colonna variazione" do
    create(:server_sample, host: primary, recorded_at: 6.days.ago,
           payload: { "database" => { "databases" => [ { "name" => "koru_production", "size_bytes" => 500 } ] } })
    create(:server_sample, host: primary, recorded_at: 1.hour.ago,
           payload: { "database" => { "databases" => [ { "name" => "koru_production", "size_bytes" => 560 } ] } })

    sign_in(owner)
    get member_monitoring_server_path(primary, tab: "hardware")

    expect(response.body).to include(I18n.t("member.databases.col_change"))
    expect(response.body).to include("+60 Bytes")
  end

  it "host di un'altra organizzazione → non trovato (anti-BOLA)" do
    other = create(:server_host, :up, name: "db-altrui",
                   database_snapshot: { "engine" => "postgresql", "reachable" => true,
                                        "databases" => [ { "name" => "segreto_production", "size_bytes" => 1 } ] })

    sign_in(owner)
    get member_monitoring_server_databases_path(other)

    expect(response).to have_http_status(:not_found)
  end

  it "host without databases → no database list on the hardware tab" do
    host = create(:server_host, :up, organization:, name: "web-1")

    sign_in(owner)
    get member_monitoring_server_path(host, tab: "hardware")

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("databases-table")
  end

  it "the old database list address lands on the hardware tab, keeping the search" do
    sign_in(owner)
    get member_monitoring_server_databases_path(primary, q: "koru")

    expect(response).to redirect_to(member_monitoring_server_path(primary, tab: "hardware", q: "koru"))
  end

  describe "pagina di un singolo database" do
    it "mostra dimensione, crescita, dove si trova e tabelle" do
      primary.update!(database_snapshot: primary.database_snapshot.merge(
        "top_tables" => [ { "database" => "koru_production", "name" => "public.events", "size_bytes" => 400 },
                          { "database" => "altro_db", "name" => "public.rumore", "size_bytes" => 900 } ]
      ))
      create(:server_sample, host: primary, recorded_at: 1.hour.ago,
             payload: { "database" => { "databases" => [ { "name" => "koru_production", "size_bytes" => 700 } ] } })

      sign_in(owner)
      get member_monitoring_server_database_path(primary, "koru_production")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("database-show")
      expect(response.body).to include("database-growth", "database-presences", "database-tables")
      expect(response.body).to include("public.events")
      expect(response.body).not_to include("public.rumore")
    end

    it "un database che non sta su quella macchina → non trovato" do
      sign_in(owner)
      get member_monitoring_server_database_path(primary, "mai_visto")

      expect(response).to have_http_status(:not_found)
    end

    it "host di un'altra organizzazione → non trovato (anti-BOLA)" do
      other = create(:server_host, :up, name: "db-altrui",
                     database_snapshot: { "engine" => "postgresql", "reachable" => true,
                                          "databases" => [ { "name" => "segreto_production", "size_bytes" => 1 } ] })

      sign_in(owner)
      get member_monitoring_server_database_path(other, "segreto_production")

      expect(response).to have_http_status(:not_found)
    end

    it "un periodo fuori elenco ricade sul default" do
      sign_in(owner)
      get member_monitoring_server_database_path(primary, "koru_production", range: "boom")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("database-range-7d")
    end

    # CYRA-474 Scenario 2: l'etichetta dichiara il periodo e segue il selettore.
    it "l'etichetta della variazione dichiara il periodo scelto" do
      sign_in(owner)

      get member_monitoring_server_database_path(primary, "koru_production", range: "7d")
      expect(response.body).to include(
        I18n.t("member.databases.show.stat_change", period: I18n.t("member.databases.range_label.7d"))
      )
      expect(I18n.t("member.databases.show.stat_change", period: "7 giorni", locale: :it))
        .to eq("Variazione (7 giorni)")

      get member_monitoring_server_database_path(primary, "koru_production", range: "30d")
      expect(response.body).to include(
        I18n.t("member.databases.show.stat_change", period: I18n.t("member.databases.range_label.30d"))
      )
    end

    it "il valore della variazione segue l'intervallo selezionato" do
      # Un balzo grande più vecchio di 7 giorni entra solo nella finestra a 30 giorni.
      create(:server_sample, host: primary, recorded_at: 20.days.ago,
             payload: { "database" => { "databases" => [ { "name" => "koru_production", "size_bytes" => 100 } ] } })
      create(:server_sample, host: primary, recorded_at: 3.days.ago,
             payload: { "database" => { "databases" => [ { "name" => "koru_production", "size_bytes" => 700 } ] } })
      create(:server_sample, host: primary, recorded_at: 1.hour.ago,
             payload: { "database" => { "databases" => [ { "name" => "koru_production", "size_bytes" => 800 } ] } })

      sign_in(owner)

      get member_monitoring_server_database_path(primary, "koru_production", range: "7d")
      expect(response.body).to include("+100 Bytes") # da 700 (3g fa) a 800

      get member_monitoring_server_database_path(primary, "koru_production", range: "30d")
      expect(response.body).to include("+700 Bytes") # da 100 (20g fa) a 800
    end

    it "member senza servers.view → negato" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)

      sign_in(member)
      get member_monitoring_server_database_path(primary, "koru_production")

      expect(response).to redirect_to(root_path)
    end
  end

  it "lists the machine's databases on the hardware tab, with no separate Database tab" do
    sign_in(owner)

    get member_monitoring_server_path(primary, tab: "hardware")
    expect(response.body).to include("server-databases", "databases-table")
    expect(response.body).not_to include("server-tab-databases", "server-database-sizes")
  end

  # CYRA-462: gerarchia di navigazione unica «server padre di database» in tutta l'area.
  describe "gerarchia di navigazione (CYRA-462)" do
    it "il breadcrumb del dettaglio database ha i Server come radice, non la flotta Database" do
      sign_in(owner)
      get member_monitoring_server_database_path(primary, "koru_production")

      crumbs = Capybara.string(response.body).all("[data-test='breadcrumb-crumb']")
      # crumbs[0] è la Home, crumbs[1] l'area (CYRA-335); la prima voce di risorsa è «Server»
      # (→ elenco server), non «Database» (flotta).
      area_root = crumbs[2]
      expect(area_root.text).to eq(I18n.t("member.servers.title"))
      expect(area_root[:href]).to eq(member_monitoring_servers_path)
      # Nessun crumb rimanda alla flotta Database come radice (la vecchia gerarchia invertita).
      # Il controllo è ristretto ai crumb: la voce di menu «Database» in sidebar ci punta legittimamente.
      expect(crumbs.map { |crumb| crumb[:href] }).not_to include(member_monitoring_databases_path)
    end
  end

  # CYRA-924 — the bar holds no count (C63): on the server tab the list count sits beside its title.
  it "puts the database count beside the section title, not in the bar" do
    sign_in(owner)
    get member_monitoring_server_path(primary, tab: "hardware")

    doc = Nokogiri::HTML(response.body)
    label = I18n.t("member.databases.count", count: 1)
    expect(doc.at_css("[data-test='databases-heading']").text.squish).to eq("#{I18n.t('member.databases.title')} #{label}")
    expect(doc.at_css("[data-test='databases-toolbar']").text).not_to include(label)
  end
end
