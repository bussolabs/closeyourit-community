# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::Databases", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let!(:primary) do
    create(:server_host, :up, organization:, name: "db-primary",
           database_snapshot: { "engine" => "postgresql", "reachable" => true, "role" => "primary",
                                # Il primary dichiara la replica connessa: senza, non assorbe nessuno.
                                "replication" => { "streaming" => true,
                                                   "replicas" => [ { "client" => "10.0.0.12", "state" => "streaming" } ] },
                                "databases" => [ { "name" => "koru_production", "size_bytes" => 800 },
                                                 { "name" => "koru_queue_production", "size_bytes" => 200 } ] })
  end
  let!(:staging) do
    create(:server_host, :up, organization:, name: "db-staging",
           database_snapshot: { "engine" => "postgresql", "reachable" => true,
                                "databases" => [ { "name" => "koru_staging", "size_bytes" => 100 } ] })
  end

  before do
    create(:membership, account: owner, organization:, role: :owner)
    create(:membership, account: member, organization:, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "non autenticato → redirect al login" do
    get member_monitoring_databases_path
    expect(response).to redirect_to(login_path)
  end

  # F105 — the sizes are the agents' last push: the header says how old the oldest one is.
  it "says how old the data is, from the machine that reported longest ago" do
    primary.update!(last_seen_at: 3.hours.ago)
    staging.update!(last_seen_at: 1.minute.ago)
    sign_in(owner)

    get member_monitoring_databases_path

    stat = Capybara.string(response.body).find("[data-test='databases-count-freshness']")
    expect(stat.text).to include("about 3 hours ago")
  end

  it "elenca i database di tutti i server della flotta" do
    sign_in(owner)
    get member_monitoring_databases_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("databases-table")
    expect(response.body).to include("koru_production", "koru_queue_production", "koru_staging")
    expect(response.body).to include("db-primary", "db-staging")
  end

  # CYRA-462 Scenario 1: sotto il titolo una riga fissa dice cosa contiene la pagina (i database trovati).
  it "mostra un sottotitolo fisso che dice cosa elenca" do
    sign_in(owner)
    get member_monitoring_databases_path

    expect(response.body).to include(I18n.t("member.databases.subtitle"))
    expect(I18n.t("member.databases.subtitle", locale: :it))
      .to eq("Tutti i database PostgreSQL trovati sulle macchine monitorate")
  end

  # CYRA-466: "quota" si legge come limite assegnato — il nome deve dire cosa misura davvero.
  it "intitola la colonna in modo che dica cosa misura, non un limite assegnato" do
    sign_in(owner)
    get member_monitoring_databases_path

    expect(I18n.t("member.databases.col_share", locale: :it)).to eq("% dei database del server")
    expect(response.body).to include(I18n.t("member.databases.col_share"))
    expect(response.body).not_to include("Quota sul server")
  end

  # CYRA-466 Scenario 2: col mouse sopra si vede su quale totale e su quale macchina è calcolata.
  it "espone nel tooltip il totale dei database dell'host e la macchina" do
    sign_in(owner)
    get member_monitoring_databases_path

    # koru_production pesa 800 sui 1000 Bytes (800+200) dei database di db-primary.
    expect(response.body).to include(
      I18n.t("member.databases.share_title", size: "800 Bytes", total: "1000 Bytes", host: "db-primary")
    )
  end

  context "con una replica del server principale" do
    let!(:standby) do
      create(:server_host, :up, organization:, name: "db-standby",
             database_snapshot: { "engine" => "postgresql", "reachable" => true, "role" => "standby",
                                  "databases" => [ { "name" => "koru_production", "size_bytes" => 803 },
                                                   { "name" => "koru_queue_production", "size_bytes" => 201 } ] })
    end

    it "mostra una riga sola per database, col conteggio delle copie" do
      sign_in(owner)
      get member_monitoring_databases_path

      expect(response.body.scan("koru_production<").size).to eq(1)
      expect(response.body).to include("database-row-replicas")
      expect(response.body).to include("db-standby") # nel title del badge
      # 3 righe (2 del cluster + 1 di staging), non 5: le gemelle della replica sono accorpate.
      expect(response.body.scan('data-test="database-row"').size).to eq(3)
    end

    it "non conta due volte lo stesso database nei totali di testata" do
      sign_in(owner)
      get member_monitoring_databases_path

      # 800 + 200 (primary) + 100 (staging) = 1100 byte, non 2104.
      expect(response.body).to include("1.07 KB")
    end

    it "filtrando sulla replica mostra i database che ospita" do
      sign_in(owner)
      get member_monitoring_databases_path, params: { server: standby.id }

      expect(response.body).to include("koru_production")
      expect(response.body).to include("db-standby")
      expect(response.body).not_to include("database-row-replicas")
    end
  end

  it "non mostra i database di un'altra organizzazione (anti-BOLA)" do
    other = create(:server_host, :up, name: "db-altrui",
                   database_snapshot: { "engine" => "postgresql", "reachable" => true,
                                        "databases" => [ { "name" => "segreto_production", "size_bytes" => 1 } ] })
    expect(other.organization_id).not_to eq(organization.id)

    sign_in(owner)
    get member_monitoring_databases_path

    expect(response.body).not_to include("segreto_production")
    expect(response.body).not_to include("db-altrui")
  end

  it "filtra per testo cercato" do
    sign_in(owner)
    get member_monitoring_databases_path, params: { q: "queue" }

    expect(response.body).to include("koru_queue_production")
    expect(response.body).not_to include(">koru_staging<")
  end

  it "filtra per server" do
    sign_in(owner)
    get member_monitoring_databases_path, params: { server: staging.id }

    expect(response.body).to include("koru_staging")
    expect(response.body).not_to include("koru_queue_production")
  end

  it "accetta anche più server insieme (forma inviata dal filtro del toolbar)" do
    sign_in(owner)
    get member_monitoring_databases_path, params: { server: [ staging.id ] }

    expect(response.body).to include("koru_staging")
    expect(response.body).not_to include("koru_queue_production")
  end

  it "mostra lo stato vuoto quando nessun server ha un database" do
    [ primary, staging ].each { |host| host.update!(database_snapshot: {}) }

    sign_in(owner)
    get member_monitoring_databases_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("databases-empty")
    expect(response.body).not_to include("databases-table")
  end

  it "avvisa quando il filtro non trova nulla, senza mostrare lo stato vuoto" do
    sign_in(owner)
    get member_monitoring_databases_path, params: { q: "nessun-database-si-chiama-cosi" }

    expect(response.body).to include("databases-no-match")
    expect(response.body).not_to include("databases-empty")
  end

  it "member senza servers.view → negato" do
    sign_in(member)
    get member_monitoring_databases_path

    expect(response).to redirect_to(root_path)
  end

  # CYRA-474: la lista deve dire cosa cresce, senza aprire i database uno per uno.
  describe "variazione a 7 giorni" do
    def snapshot(host, at, databases)
      create(:server_sample, host:, recorded_at: at,
             payload: { "database" => { "databases" => databases } })
    end

    it "mostra la colonna della variazione, col periodo nel titolo e ordinabile" do
      sign_in(owner)
      get member_monitoring_databases_path

      expect(response.body).to include(I18n.t("member.databases.col_change"))
      # In maiuscoletto «(7g)» diventava «(7G)» e si leggeva come sette gigabyte.
      expect(I18n.t("member.databases.col_change", locale: :it)).to eq("Variazione 7 giorni")
      expect(response.body).to include('data-test="database-row-change"')
      # L'intestazione è un link di ordinamento sulla chiave "change".
      expect(response.body).to include("sort=-change")
    end

    it "riempie la variazione dal primo all'ultimo campione, con la direzione" do
      snapshot(primary, 6.days.ago, [ { "name" => "koru_production", "size_bytes" => 500 } ])
      snapshot(primary, 1.hour.ago, [ { "name" => "koru_production", "size_bytes" => 800 } ])

      sign_in(owner)
      get member_monitoring_databases_path

      expect(response.body).to include('data-test="database-row-change-value"')
      expect(response.body).to include('data-icon="arrow-up"') # cresce
      expect(response.body).to include("+300 Bytes")
    end

    it "mostra un trattino, non uno zero, quando manca la storia (database più giovane della finestra)" do
      sign_in(owner)
      get member_monitoring_databases_path

      # Nessun campione storico: ogni riga ha variazione "—" con la spiegazione nel tooltip.
      expect(response.body).to include('data-test="database-row-change"')
      expect(response.body).to include(I18n.t("member.databases.change_new_title"))
      expect(response.body).not_to include('data-test="database-row-change-value"')
    end

    it "ordina per variazione: chi cresce di più sale, oltre l'ordine per dimensione" do
      # koru_production è più grande ma cresce poco; koru_queue_production è piccolo ma esplode.
      snapshot(primary, 6.days.ago, [ { "name" => "koru_production", "size_bytes" => 790 },
                                      { "name" => "koru_queue_production", "size_bytes" => 100 } ])
      snapshot(primary, 1.hour.ago, [ { "name" => "koru_production", "size_bytes" => 800 },
                                      { "name" => "koru_queue_production", "size_bytes" => 600 } ])

      sign_in(owner)
      get member_monitoring_databases_path, params: { sort: "-change" }

      body = response.body
      # Per crescita: koru_queue_production (+500) davanti a koru_production (+10),
      # l'opposto dell'ordine per dimensione di default.
      expect(body.index("koru_queue_production<")).to be < body.index("koru_production<")
    end
  end
end
