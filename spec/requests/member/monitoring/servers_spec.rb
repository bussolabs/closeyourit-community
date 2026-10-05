# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::Servers", type: :request do
  let(:organization) { create(:organization) }
  let!(:host) { create(:server_host, organization: organization, name: "apps", status: :up, last_seen_at: Time.current) }

  # I tre attori nascono solo quando un esempio li nomina (CYRA-551): un `before` comune li creava
  # tutti e tre, e il viewer si porta dietro anche un ruolo, un permesso e un'assegnazione — sei
  # insert che la gran parte degli esempi, che entra da owner o da member, non usa.
  let(:owner) { account_with_membership(:owner) }
  let(:member) { account_with_membership(:member) }
  # viewer = membro semplice che vede i server solo grazie a un ruolo con la chiave servers.view.
  let(:viewer) do
    account_with_membership(:member).tap do |account|
      role = create(:role, organization: organization, name: "Ops viewer")
      create(:role_permission, role: role, permission_key: "servers.view")
      create(:account_role, account: account, organization: organization, role: role)
    end
  end

  def account_with_membership(role)
    create(:account).tap do |account|
      create(:membership, account: account, organization: organization, role: role)
    end
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Progetto uptime-capable dell'org con environment dichiarato, collegato all'host di test.
  def create_link(project_name:)
    project = create(:project, organization: organization, name: project_name)
    project.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: organization))
    environment = create(:environment, organization: organization)
    project.environments << environment
    create(:environment_host, project:, environment:, host:)
  end

  # Progetto uptime-capable dell'org SENZA host collegato: il candidato "rilevato" dai dati (CYRA-471).
  def create_uptime_project(name:)
    project = create(:project, organization: organization, name: name)
    project.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: organization))
    project
  end

  describe "GET index" do
    # F103 — C78: the state cell says why a machine is down: it stopped sending data, and since when.
    it "a down machine says since when it stopped sending data" do
      host.update!(status: :down, last_seen_at: 3.hours.ago)
      sign_in(owner)

      get member_monitoring_servers_path

      reason = Capybara.string(response.body).find("[data-test='server-down-reason-#{host.id}']")
      expect(reason.text.strip).to eq("no data for about 3 hours")
    end

    it "non autenticato → redirect al login" do
      get member_monitoring_servers_path
      expect(response).to redirect_to(login_path)
    end

    it "owner → 200 con la fleet" do
      sign_in(owner)
      get member_monitoring_servers_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("apps")
    end

    # E11 — the Load column says what its three numbers are, behind the info mark on the header.
    it "explains the Load column on its header" do
      sign_in(owner)
      get member_monitoring_servers_path

      expect(response.body).to include('data-test="servers-col-load-hint"')
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.servers.col_load_hint")))
    end

    # CYRA-469 — dal conteggio «Server collegati» della pagina dei codici si arriva alla flotta
    # filtrata su quel codice: solo le sue macchine, con un banner e l'uscita in un clic.
    context "filtro per codice di enrollment" do
      it "mostra solo le macchine registrate con quel codice, con il banner" do
        token = create(:server_enrollment_token, organization: organization, name: "fleet")
        db = create(:server_host, organization: organization, name: "db-1", enrollment_token: token)
        sign_in(owner)

        get member_monitoring_servers_path(enrollment_token: token.id)

        expect(response.body).to include("server-link-#{db.id}")
        expect(response.body).not_to include("server-link-#{host.id}")
        expect(response.body).to include("data-test=\"servers-token-filter\"")
        expect(response.body).to include(I18n.t("member.servers.filtered_by_token", name: "fleet"))
      end

      it "un codice di un'altra org non filtra nulla e non mostra il banner" do
        other = create(:server_enrollment_token, name: "estraneo")
        sign_in(owner)

        get member_monitoring_servers_path(enrollment_token: other.id)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("apps")
        expect(response.body).not_to include("data-test=\"servers-token-filter\"")
      end

      it "un valore non-uuid viene ignorato senza errori" do
        sign_in(owner)

        get member_monitoring_servers_path(enrollment_token: "non-un-uuid")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("apps")
      end
    end

    # CYRA-462 Scenario 1: sotto il titolo una riga fissa dice cosa contiene la pagina (le macchine).
    it "mostra un sottotitolo fisso che dice cosa elenca" do
      sign_in(owner)
      get member_monitoring_servers_path

      expect(response.body).to include(I18n.t("member.servers.subtitle"))
      expect(I18n.t("member.servers.subtitle", locale: :it)).to eq("Le macchine che l'agent monitora")
    end

    it "la colonna dell'ultimo contatto parla di dati, non del gergo «push»" do
      sign_in(owner)
      get member_monitoring_servers_path

      expect(response.body).to include(I18n.t("member.servers.col_last_seen"))
      expect(I18n.t("member.servers.col_last_seen", locale: :it)).to eq("Ultimo dato")
    end

    it "mostra oltre 10 host in una sola pagina (densità fleet, per > TABLE_PER_PAGE)" do
      # 1 host ("apps") + 12 "zzz-host-NN" = 13 in flotta. Con TABLE_PER_PAGE (10) gli ultimi
      # finirebbero in pagina 2; la fleet usa SERVERS_PER_PAGE (50) → tutti in pagina 1.
      12.times { |i| create(:server_host, organization: organization, name: format("zzz-host-%02d", i), status: :up, last_seen_at: Time.current) }
      sign_in(owner)
      get member_monitoring_servers_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("zzz-host-11")
    end

    it "member senza servers.view → redirect (forbidden)" do
      sign_in(member)
      get member_monitoring_servers_path
      expect(response).to redirect_to(root_path)
    end

    it "member con servers.view → 200" do
      sign_in(viewer)
      get member_monitoring_servers_path
      expect(response).to have_http_status(:ok)
    end

    it "mostra il badge di ruolo database solo sugli host con database" do
      create(:server_host, organization: organization, name: "db-primary", status: :up,
             last_seen_at: Time.current, db_role: "primary")
      sign_in(owner)

      get member_monitoring_servers_path

      expect(response.body).to include("server-db-role-badge")
      expect(response.body.scan("server-db-role-badge").size).to eq(1)
    end

    it "filtra per status e ricerca" do
      create(:server_host, organization: organization, name: "worker", status: :down)
      sign_in(owner)

      get member_monitoring_servers_path, params: { status: [ "down" ] }
      expect(response.body).to include("worker")
      expect(response.body).not_to include("server-link-#{host.id}")

      get member_monitoring_servers_path, params: { q: "apps" }
      expect(response.body).to include("server-link-#{host.id}")
    end

    # CYRA-465 — su una VM i sensori di temperatura non esistono: la colonna e la sua chiave di
    # ordinamento sono spazio e scelte per un dato che non arriverà. Compaiono solo se la flotta lo
    # riporta, e il flag deriva dai dati (un bare-metal futuro la fa ricomparire da sé).
    context "colonna temperatura (CYRA-465)" do
      it "è assente, con la sua chiave di ordinamento, quando nessuna macchina la riporta" do
        sign_in(owner)

        get member_monitoring_servers_path

        expect(response.body).not_to include('data-test="sort-temp"')
      end

      it "compare appena una macchina della flotta riporta la temperatura" do
        create(:server_sample, host: host, temp_max: 48.5)
        sign_in(owner)

        get member_monitoring_servers_path

        expect(response.body).to include('data-test="sort-temp"')
      end

      it "un ?sort=temp costruito a mano non rompe la pagina quando la colonna è nascosta" do
        sign_in(owner)

        get member_monitoring_servers_path(sort: "temp")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("apps")
      end
    end
  end

  describe "GET show" do
    it "owner → 200 con sezioni" do
      create(:server_sample, host: host, recorded_at: 1.minute.ago)
      create(:server_container_sample, host: host, name: "web", recorded_at: 1.minute.ago)
      sign_in(owner)

      # The other tabs' blocks are covered by server_tabs_spec; one request here (Prosopite).
      get member_monitoring_server_path(host, tab: "workloads")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("server-containers", "server-systemd")
    end

    # CYRA-677 — il pannello top processi compare solo quando l'ultimo campione li porta (agent
    # aggiornato): niente riquadro vuoto sulle macchine con agent vecchio.
    it "campione con processi → pannello top processi" do
      create(:server_sample, host: host, recorded_at: 1.minute.ago,
             payload: { "processes" => [ { "pid" => 42, "name" => "postgres",
                                           "cpu_pct" => 41.5, "mem_bytes" => 812_000_000 } ] })
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "workloads")

      expect(response.body).to include("server-processes")
      expect(response.body).to include("postgres")
      expect(response.body).to include("41.5")
    end

    it "campione senza processi → nessun pannello" do
      create(:server_sample, host: host, recorded_at: 1.minute.ago)
      sign_in(owner)

      get member_monitoring_server_path(host)

      expect(response.body).not_to include("server-processes")
    end

    it "host di un'altra org → 404 (anti-BOLA)" do
      other = create(:server_host)
      sign_in(owner)

      get member_monitoring_server_path(other)

      expect(response).to have_http_status(:not_found)
    end

    # CYRA-465 — il grafico temperatura occupava un quarto della griglia anche su una macchina che non
    # espone i sensori (VM): sempre vuoto, si imparava a ignorarlo. Ora compare solo se la macchina la
    # riporta; altrimenti nei Dettagli è scritto perché il dato manca.
    context "temperatura non esposta dall'hardware (CYRA-465)" do
      it "senza sensori: niente grafico, e i Dettagli spiegano perché manca" do
        create(:server_sample, host: host, temp_max: nil, recorded_at: 1.minute.ago)
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "overview")

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('data-test="server-chart-temp"')
        expect(response.body).to include('data-test="server-temp-unavailable"')
        expect(response.body).to include(I18n.t("member.servers.show.temp_unavailable"))
      end

      it "con una temperatura riportata: il grafico c'è e la riga di assenza no" do
        create(:server_sample, host: host, temp_max: 48.5, recorded_at: 1.minute.ago)
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "metrics")

        expect(response.body).to include('data-test="server-chart-temp"')
        expect(response.body).not_to include('data-test="server-temp-unavailable"')
      end
    end

    # CYRA-472: i grafici dichiarano il fondo scala. Senza, una colonna a metà altezza non dice se
    # sia metà di 100% o metà di un disco da 42 GB.
    describe "scala dei grafici di sistema" do
      it "mostra l'asse percentuale con lo zero su cpu/mem/disk" do
        create(:server_sample, host: host, recorded_at: 1.minute.ago)
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "metrics")

        page = Capybara.string(response.body)
        cpu = page.find("[data-test='server-chart-cpu']")
        expect(cpu).to have_text("100%")
        expect(cpu).to have_css("span[style='bottom: 0']", text: "0")
      end

      it "dichiara la memoria totale della macchina accanto al titolo e in cifra assoluta" do
        host.update!(memory_total_bytes: 32 * 1_073_741_824, mem_pct: 50.0)
        create(:server_sample, host: host, recorded_at: 1.minute.ago)
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "metrics")

        page = Capybara.string(response.body)
        expect(page.find("[data-test='server-chart-mem-total']")).to have_text("32 GB")
        expect(page.find("[data-test='server-chart-mem-current']")).to have_text("16 GB · 50%")
      end

      it "il tooltip di una colonna porta i GB misurati in quel momento, non ricalcolati" do
        # La macchina oggi ha 32 GB, ma il campione fu preso quando ne aveva 16: il tooltip deve
        # dire gli 8 GB di allora. Col ricalcolo sulla percentuale direbbe 16 GB.
        host.update!(memory_total_bytes: 32 * 1_073_741_824)
        create(:server_sample, host: host, recorded_at: 1.minute.ago, mem_pct: 50.0,
               payload: { "mem" => { "total_gb" => 16.0, "used_gb" => 8.0 } })
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "metrics", range: "30m")

        bars = Capybara.string(response.body).find("[data-test='server-mem-buckets']")
        expect(bars).to have_css("[data-value='8 GB · 50%']")
      end

      it "elenca i dischi con lo spazio libero, marcando quello del grafico" do
        create(:server_sample, host: host, recorded_at: 1.minute.ago, disk_pct: 48.0,
               payload: { "disk" => { "total_gb" => 42.0, "used_gb" => 20.2 },
                          "extra_fs" => { "pgdata" => { "d" => 1000.0, "du" => 930.0 } } })
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "metrics")

        disks = Capybara.string(response.body).find("[data-test='server-disks']")
        expect(disks).to have_text(I18n.t("member.servers.show.disk_free", free: "21.8 GB", total: "42 GB"))
        expect(disks).to have_text(I18n.t("member.servers.show.disk_free", free: "70 GB", total: "1000 GB"))
        expect(disks).to have_text(I18n.t("member.servers.show.disk_charted"))
      end

      it "senza dischi riportati la sezione non compare" do
        create(:server_sample, host: host, recorded_at: 1.minute.ago, payload: {})
        sign_in(owner)

        get member_monitoring_server_path(host)

        expect(response.body).not_to include("server-disks")
      end

      it "senza il totale della macchina il grafico resta in sola percentuale" do
        host.update!(memory_total_bytes: nil, mem_pct: 50.0)
        create(:server_sample, host: host, recorded_at: 1.minute.ago, payload: {})
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "metrics")

        page = Capybara.string(response.body)
        expect(page).to have_no_css("[data-test='server-chart-mem-total']")
        expect(page.find("[data-test='server-chart-mem-current']")).to have_text("50%")
      end
    end

    # CYRA-457: all'apertura senza ?range il default è la finestra coperta dai dati, non 24h quasi vuota.
    it "senza ?range apre sulla finestra coperta dai dati (host giovane → 30m attivo)" do
      create(:server_sample, host: host, recorded_at: 5.minutes.ago)
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "metrics")

      # Every chart panel carries the selector, all on the same range.
      active = Capybara.string(response.body).all("[data-test='range-30m']")
      expect(active).not_to be_empty
      expect(active.map { |link| link[:class] }).to all(include("bg-white"))
    end

    it "rispetta il ?range esplicito scelto dall'utente" do
      create(:server_sample, host: host, recorded_at: 5.minutes.ago)
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "metrics", range: "7d")

      # Every chart panel carries the selector, all on the same range.
      active = Capybara.string(response.body).all("[data-test='range-7d']")
      expect(active).not_to be_empty
      expect(active.map { |link| link[:class] }).to all(include("bg-white"))
    end

    # CYRA-457: su una finestra più larga della storia dell'host, il tratto iniziale non misurato è
    # dichiarato a parole (riga hires) e reso con la fascia tratteggiata (bg-hatch), non a valore zero.
    it "dichiara da quando ci sono misure quando la finestra supera la storia dell'host" do
      create(:server_sample, host: host, recorded_at: 30.minutes.ago)
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "metrics", range: "24h")

      expect(response.body).to include("hires-since")
      expect(response.body).to include("bg-hatch")
    end

    it "owner vede gli environment di progetto collegati" do
      link = create_link(project_name: "Storefront")
      sign_in(owner)

      get member_monitoring_server_path(host)

      expect(response.body).to include("server-projects")
      expect(response.body).to include("Storefront")
      expect(response.body).to include(link.environment.label)
    end

    it "viewer con solo servers.view NON vede il progetto non assegnatogli (anti-leak)" do
      create_link(project_name: "Segretissimo")
      sign_in(viewer)

      get member_monitoring_server_path(host)

      expect(response.body).to include("server-projects")
      expect(response.body).not_to include("Segretissimo")
    end

    it "link stale (environment s-dichiarato) non compare" do
      # A name the page shell never prints: "Storefront" is in the assistant's example sentences.
      link = create_link(project_name: "Orphaned Shop")
      Connections::ProjectEnvironment.where(project: link.project, environment: link.environment).delete_all
      sign_in(owner)

      get member_monitoring_server_path(host)

      expect(response.body).not_to include("Orphaned Shop")
    end

    # CYRA-471 — il numero dei collegati non deve sembrare un conteggio automatico di ciò che gira sulla
    # macchina: una riga spiega cos'è, e i progetti riconosciuti dai dati sono proposti da confermare.
    context "riquadro dei progetti collegati" do
      it "spiega sempre che il collegamento si imposta a mano" do
        sign_in(owner)

        get member_monitoring_server_path(host)

        expect(response.body).to include("server-projects-help")
      end

      it "senza collegamenti né progetti riconosciuti invita ad aprire un progetto" do
        sign_in(owner)

        get member_monitoring_server_path(host)

        expect(response.body).to include("server-projects-empty-cta")
        expect(response.body).to include(member_projects_path)
      end

      it "propone i progetti riconosciuti dai dati della macchina, non ancora collegati" do
        detected = create_uptime_project(name: "Closeyourit")
        create(:server_container_sample, host: host, name: "closeyourit-web-a1b2", recorded_at: 1.minute.ago)
        sign_in(owner)

        get member_monitoring_server_path(host)

        expect(response.body).to include("server-projects-detected")
        expect(response.body).to include(member_project_environments_path(detected))
        expect(response.body).to include(I18n.t("member.servers.show.projects_detected", count: 1))
      end

      it "riconosce anche i progetti dai nomi dei database dello snapshot" do
        detected = create_uptime_project(name: "Acme")
        host.update!(database_snapshot: { "databases" => [ { "name" => "acme_production" } ] })
        sign_in(owner)

        get member_monitoring_server_path(host)

        expect(response.body).to include(member_project_environments_path(detected))
      end

      it "non ripropone un progetto già collegato alla macchina" do
        link = create_link(project_name: "Storefront")
        create(:server_container_sample, host: host, name: "storefront-web-a1b2", recorded_at: 1.minute.ago)
        sign_in(owner)

        get member_monitoring_server_path(host)

        expect(response.body).not_to include("server-projects-detected")
        expect(response.body).not_to include(member_project_environments_path(link.project))
      end
    end

    describe "pannello database" do
      let(:snapshot) do
        {
          "engine" => "postgresql", "reachable" => true, "version" => "16.2", "role" => "primary",
          "connections" => { "total" => 42, "max" => 100, "by_state" => { "active" => 5, "idle" => 37 } },
          "replication" => { "streaming" => true, "lag_seconds" => 0.12,
                             "replicas" => [ { "client" => "10.0.0.10", "state" => "streaming" } ] },
          "databases" => [ { "name" => "app_production", "size_bytes" => 123_456_789 } ],
          "top_tables" => [ { "database" => "app_production", "name" => "public.events", "size_bytes" => 98_765_432 } ]
        }
      end

      it "host con database → pannello con stato, ruolo, connessioni, replica e dimensioni" do
        host.update!(database_snapshot: snapshot, db_role: "primary")
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "hardware")

        expect(response.body).to include("server-database")
        expect(response.body).to include("server-db-role")
        expect(response.body).to include("42")
        expect(response.body).to include("app_production")
        expect(response.body).to include("public.events")
        expect(response.body).to include("10.0.0.10")
        expect(response.body).not_to include("server-database-unreachable")
      end

      it "database non raggiungibile → avviso nel pannello" do
        host.update!(database_snapshot: { "engine" => "postgresql", "reachable" => false, "role" => "standby" },
                     db_role: "standby")
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "hardware")

        expect(response.body).to include("server-database-unreachable")
      end

      it "host senza database → nessun pannello" do
        sign_in(owner)

        get member_monitoring_server_path(host)

        expect(response.body).not_to include("server-database")
      end
    end

    # CYRA-463 — la scheda elencava per intero decine di servizi solo per dire "0 failed". Ora di
    # default si vedono i soli servizi in errore (o un messaggio esplicito), l'elenco completo sta
    # dietro un blocco richiudibile, e lì le unit a riposo sono distinte da quelle ferme in modo anomalo.
    describe "servizi systemd (CYRA-463)" do
      it "di default elenca solo i servizi in errore; l'elenco completo sta nel blocco richiudibile" do
        host.update!(services_total: 3, services_failed: 1, systemd_services: [
          { "name" => "nginx.service", "state" => "active", "sub" => "running" },
          { "name" => "postgresql.service", "state" => "failed", "sub" => "failed" },
          { "name" => "dmesg.service", "state" => "inactive", "sub" => "dead" }
        ])
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "workloads")

        page = Capybara.string(response.body)
        failed = page.find("[data-test='server-systemd-failed']")
        expect(failed).to have_text("postgresql.service")
        expect(failed).to have_no_text("nginx.service")
        expect(failed).to have_no_text("dmesg.service")

        full = page.find("[data-test='server-systemd-full']", visible: :all)
        expect(full).to have_text("nginx.service")
        expect(full).to have_text("dmesg.service")
        expect(full).to have_text("postgresql.service")
      end

      it "senza servizi in errore mostra un messaggio esplicito al posto dell'elenco" do
        host.update!(services_total: 1, services_failed: 0, systemd_services: [
          { "name" => "nginx.service", "state" => "active", "sub" => "running" }
        ])
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "workloads")

        page = Capybara.string(response.body)
        expect(page).to have_css("[data-test='server-systemd-all-ok']")
        expect(page).to have_no_css("[data-test='server-systemd-failed']")
        expect(page).to have_css("[data-test='server-systemd-full']", visible: :all)
      end

      it "nell'elenco completo distingue le unit a riposo da quelle ferme in modo anomalo" do
        host.update!(services_total: 2, services_failed: 0, systemd_services: [
          { "name" => "dmesg.service", "state" => "inactive", "sub" => "dead" },
          { "name" => "myapp.service", "state" => "inactive", "sub" => "dead" }
        ])
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "workloads")

        full = Capybara.string(response.body).find("[data-test='server-systemd-full']", visible: :all)
        idle = full.find("[data-test='server-systemd-row']", text: "dmesg.service", visible: :all)
        stopped = full.find("[data-test='server-systemd-row']", text: "myapp.service", visible: :all)
        expect(idle["data-kind"]).to eq("idle")
        expect(stopped["data-kind"]).to eq("stopped")
      end

      it "nessun servizio riportato dall'agent → messaggio dedicato, nessun elenco" do
        host.update!(services_total: 0, services_failed: 0, systemd_services: [])
        sign_in(owner)

        get member_monitoring_server_path(host, tab: "workloads")

        page = Capybara.string(response.body)
        expect(page).to have_css("[data-test='server-systemd-empty']")
        expect(page).to have_no_css("[data-test='server-systemd-full']", visible: :all)
      end
    end
  end

  # CYRA-458 Scenario 1: accanto al valore di occupazione compare il limite oltre cui scatta un avviso.
  describe "GET index — il limite accanto ai valori" do
    it "mostra il limite della regola org accanto a cpu/mem/disco" do
      create(:alerting_rule, organization:, event_type: :server_disk, name: "Disk", threshold: 80)
      host.update!(disk_pct: 55)
      sign_in(owner)

      get member_monitoring_servers_path

      expect(response.body).to include("server-threshold-disk-#{host.id}")
      expect(response.body).to include("80")
    end

    it "senza regola né override non mostra alcun limite per la metrica" do
      sign_in(owner)

      get member_monitoring_servers_path

      expect(response.body).not_to include("server-threshold-disk-#{host.id}")
    end
  end

  # CYRA-458 Scenario 1 (dettaglio) + Scenario 2: limite nei grafici e pannello delle regole attive.
  describe "GET show — limiti e regole di avviso" do
    it "mostra il limite accanto al valore corrente di cpu/mem/disco" do
      create(:alerting_rule, organization:, event_type: :server_cpu, name: "CPU", threshold: 90)
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).to include("server-threshold-cpu")
      expect(response.body).to include("90")
    end

    it "la soglia per-macchina prevale su quella della regola org" do
      create(:alerting_rule, organization:, event_type: :server_disk, name: "Disk", threshold: 80)
      host.update!(disk_threshold: 60)
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "metrics")

      expect(response.body).to include("server-threshold-disk")
      expect(response.body).to include("60")
    end

    it "elenca le regole che riguardano la macchina con l'ultimo scatto e il link alla regola" do
      rule = create(:alerting_rule, :server_down, organization:, name: "Server giù")
      create(:alerting_notification, organization:, subject: host, rule:, event_type: :server_down,
                                     created_at: 2.hours.ago)
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "alerts")

      expect(response.body).to include("server-alert-rules")
      expect(response.body).to include("Server giù")
      expect(response.body).to include("server-alert-rule-#{rule.id}")
      expect(response.body).to include(member_alerting_rule_path(rule))
      expect(response.body).to include("server-alert-last-#{rule.id}")
    end

    it "il tipo di evento accanto alla regola compare solo se dice qualcosa in più del nome" do
      titolo = ::Notifications::Catalog.entry(:server_down).title
      uguale = create(:alerting_rule, :server_down, organization:, name: titolo)
      diversa = create(:alerting_rule, :server_down, organization:, name: "Server giù")
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "alerts")

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='server-alert-event-#{uguale.id}']")).to be_nil
      expect(doc.at_css("[data-test='server-alert-event-#{diversa.id}']").text).to eq(titolo)
    end

    it "una regola che non è mai scattata su questa macchina lo dichiara" do
      create(:alerting_rule, :server_down, organization:, name: "Server giù")
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "alerts")

      expect(response.body).to include(I18n.t("member.servers.alerts.never_triggered"))
    end

    it "senza regole server dichiara che nessuna copre la macchina" do
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "alerts")

      expect(response.body).to include("server-alert-rules-empty")
    end
  end

  describe "PATCH update (rename)" do
    it "owner rinomina" do
      sign_in(owner)
      patch member_monitoring_server_path(host), params: { confirm: "1", name: "apps-prod" }

      expect(host.reload.name).to eq("apps-prod")
      expect(response).to redirect_to(member_monitoring_server_path(host))
    end

    it "nome vuoto → 422 con errori" do
      sign_in(owner)
      patch member_monitoring_server_path(host), params: { name: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(host.reload.name).to eq("apps")
    end

    it "viewer senza servers.manage → redirect (forbidden)" do
      sign_in(viewer)
      patch member_monitoring_server_path(host), params: { name: "x" }

      expect(response).to redirect_to(root_path)
      expect(host.reload.name).to eq("apps")
    end

    # CYRA-458: la soglia diversa per una singola macchina si cambia dove sta il numero (sull'host).
    it "owner imposta le soglie per-macchina" do
      sign_in(owner)
      patch member_monitoring_server_path(host),
            params: { confirm: "1", name: "apps", cpu_threshold: "70", mem_threshold: "85", disk_threshold: "90" }

      expect(host.reload).to have_attributes(cpu_threshold: 70, mem_threshold: 85, disk_threshold: 90)
      expect(response).to redirect_to(member_monitoring_server_path(host))
    end

    it "svuotare una soglia la riporta al valore di partenza della regola (nil)" do
      host.update!(cpu_threshold: 70)
      sign_in(owner)
      patch member_monitoring_server_path(host), params: { confirm: "1", name: "apps", cpu_threshold: "" }

      expect(host.reload.cpu_threshold).to be_nil
    end

    it "una soglia fuori dall'intervallo percentuale → 422" do
      sign_in(owner)
      patch member_monitoring_server_path(host), params: { name: "apps", cpu_threshold: "150" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(host.reload.cpu_threshold).to be_nil
    end
  end

  describe "GET edit — i campi soglia" do
    it "mostra i campi per le soglie per-macchina" do
      sign_in(owner)

      get edit_member_monitoring_server_path(host)

      expect(response.body).to include("server-cpu-threshold")
      expect(response.body).to include("server-mem-threshold")
      expect(response.body).to include("server-disk-threshold")
    end
  end

  describe "azioni di stato" do
    before { sign_in(owner) }

    it "pause → paused, resume → pending" do
      patch pause_member_monitoring_server_path(host), params: { confirm: "1" }
      expect(host.reload.status_paused?).to be(true)

      patch resume_member_monitoring_server_path(host), params: { confirm: "1" }
      expect(host.reload.status_pending?).to be(true)
    end

    # CYRA-468 — scollegare è un'azione delicata: come più in basso nella stessa pagina, va confermata
    # riscrivendo il nome esatto della macchina. Il ripristino (unrevoke) resta a un clic.
    it "revoke con il nome esatto marca revoked_at, unrevoke lo azzera" do
      patch revoke_member_monitoring_server_path(host), params: { confirm: "1", confirmation: host.name }
      expect(host.reload.revoked?).to be(true)

      patch unrevoke_member_monitoring_server_path(host), params: { confirm: "1" }
      expect(host.reload.revoked?).to be(false)
    end

    it "revoke senza il nome esatto non scollega e lo dice" do
      patch revoke_member_monitoring_server_path(host), params: { confirm: "1", confirmation: "sbagliato" }

      expect(host.reload.revoked?).to be(false)
      expect(flash[:alert]).to eq(I18n.t("member.servers.actions.confirmation_invalid"))
    end
  end

  # CYRA-245 — sostituire la credenziale di una macchina che sta ancora riportando è un gesto
  # esplicito di una persona: apre una finestra, e solo dentro quella finestra la sonda reinstallata
  # prende il posto della precedente. Prima bastava il codice della flotta più l'impronta, e chiunque
  # poteva farlo dall'esterno senza che nessuno se ne accorgesse.
  describe "PATCH reenroll — riadozione della macchina" do
    it "con il nome esatto apre la finestra e archivia il tentativo registrato" do
      host.update!(enrollment_conflict_at: Time.current)
      sign_in(owner)

      patch reenroll_member_monitoring_server_path(host), params: { confirm: "1", confirmation: host.name }

      expect(host.reload.reenrollment_requested_at).to be_present
      expect(host.enrollment_conflict_at).to be_nil
      expect(response).to redirect_to(member_monitoring_server_path(host))
    end

    it "senza il nome esatto non apre niente e lo dice" do
      sign_in(owner)

      patch reenroll_member_monitoring_server_path(host), params: { confirm: "1", confirmation: "sbagliato" }

      expect(host.reload.reenrollment_requested_at).to be_nil
      expect(flash[:alert]).to eq(I18n.t("member.servers.actions.confirmation_invalid"))
    end

    it "chi può solo guardare la flotta non può riadottare" do
      sign_in(viewer)

      patch reenroll_member_monitoring_server_path(host), params: { confirmation: host.name }

      expect(host.reload.reenrollment_requested_at).to be_nil
    end

    it "la scheda dice che qualcuno ha provato a prendere il posto della macchina" do
      host.update!(enrollment_conflict_at: Time.current)
      sign_in(owner)

      get member_monitoring_server_path(host)

      expect(response.body).to include("server-enrollment-conflict")
      expect(response.body).to include("server-reenroll-confirm")
    end
  end

  describe "DELETE destroy" do
    # CYRA-468 — l'eliminazione è definitiva e cancella lo storico: pretende il nome esatto della
    # macchina, la stessa conferma per digitazione delle azioni operative.
    it "owner elimina host e serie con il nome esatto" do
      create(:server_sample, host: host)
      sign_in(owner)

      expect { delete member_monitoring_server_path(host), params: { confirm: "1", confirmation: host.name } }
        .to change(Servers::Host, :count).by(-1)
        .and change(Servers::Sample, :count).by(-1)

      expect(response).to redirect_to(member_monitoring_servers_path)
    end

    it "senza il nome esatto non elimina niente e lo dice" do
      create(:server_sample, host: host)
      sign_in(owner)

      expect { delete member_monitoring_server_path(host), params: { confirm: "1", confirmation: "sbagliato" } }
        .to not_change(Servers::Host, :count)
        .and not_change(Servers::Sample, :count)

      expect(flash[:alert]).to eq(I18n.t("member.servers.actions.confirmation_invalid"))
    end
  end

  # CYRA-468 — la barra delle azioni: etichette che dicono su cosa agiscono e le due azioni che fanno
  # perdere dati (scollega, elimina) tolte dalla prima fila, in un menu con conferma per digitazione.
  describe "GET show — le azioni delicate" do
    before { sign_in(owner) }

    it "le etichette dicono esplicitamente su cosa agiscono" do
      get member_monitoring_server_path(host)

      expect(response.body).to include(I18n.t("member.servers.actions.pause"))
      expect(response.body).to include(I18n.t("member.servers.actions.revoke_title"))
    end

    it "scollega ed elimina vivono nel menu con conferma per digitazione" do
      get member_monitoring_server_path(host)

      expect(response.body).to include("server-manage-menu")
      expect(response.body).to include("server-revoke-confirm")
      expect(response.body).to include("server-delete-confirm")
    end

    it "il messaggio di eliminazione dice quanti giorni di storico si perdono" do
      get member_monitoring_server_path(host)

      days = ::Servers::Retention.for(host.organization)
      expect(response.body).to include(I18n.t("member.servers.actions.delete_impact", count: days))
    end
  end

  describe "azioni operative" do
    before { create(:server_host_token, host:) }

    it "owner accoda aggiornamenti solo con conferma esatta" do
      sign_in(owner)
      expect do
        post member_monitoring_server_actions_path(host),
             params: { confirm: "1", confirmation: host.name, kind: "apply_security_updates" }
      end.to change(Servers::Action, :count).by(1)
      expect(Servers::Action.last).to have_attributes(host:, requested_by: owner, status: "queued")
    end

    it "conferma errata non accoda" do
      sign_in(owner)
      expect do
        post member_monitoring_server_actions_path(host), params: { confirmation: "altro", kind: "reboot" }
      end.not_to change(Servers::Action, :count)
    end

    it "viewer senza servers.execute non accoda" do
      sign_in(viewer)
      expect do
        post member_monitoring_server_actions_path(host), params: { confirmation: host.name, kind: "reboot" }
      end.not_to change(Servers::Action, :count)
      expect(response).to redirect_to(root_path)
    end

    # Il difetto originale: la coda mostrava lo stato grezzo dell'enum ("queued") e nient'altro, così
    # un'azione presa in carico un minuto dopo sembrava non essere mai partita.
    it "la coda dice in italiano dove si trova l'azione e perché sta aspettando" do
      create(:server_action, host:, organization:)
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "operations")

      expect(response.body).to include(I18n.t("member.servers.action_queue.statuses.queued"))
      expect(response.body).to include("server-action-detail")
      expect(response.body).to include("usually within a minute")
      expect(response.body).not_to include(">queued<")
    end

    it "mostra l'esito dell'azione conclusa, non solo che è finita" do
      create(:server_action, host:, organization:, status: :succeeded, exit_code: 0,
                             started_at: 2.minutes.ago, finished_at: 1.minute.ago,
                             output: "No packages found that can be upgraded unattended")
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "operations")

      expect(response.body).to include(I18n.t("member.servers.action_queue.statuses.succeeded"))
      expect(response.body).to include("No packages found that can be upgraded unattended")
    end

    # Il conto che spiega perché il totale non scende con i soli aggiornamenti di sicurezza.
    it "distingue gli aggiornamenti di sicurezza dagli altri" do
      host.update!(updates_available: 15, security_updates_available: 0)
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "overview")
      expect(response.body).to include("server-security-updates")

      get member_monitoring_server_path(host, tab: "operations")
      expect(response.body).to include("server-updates-breakdown")
    end

    it "offre il pulsante di tutti gli aggiornamenti solo agli agent che lo supportano" do
      host.update!(agent_version: "0.7.0")
      sign_in(owner)
      get member_monitoring_server_path(host, tab: "operations")
      expect(response.body).not_to include("server-action-all-updates")

      host.update!(agent_version: "0.8.0")
      get member_monitoring_server_path(host, tab: "operations")
      expect(response.body).to include("server-action-all-updates")
    end

    it "owner accoda tutti gli aggiornamenti su un agent che li supporta" do
      host.update!(agent_version: "0.8.0")
      sign_in(owner)

      expect do
        post member_monitoring_server_actions_path(host),
             params: { confirm: "1", confirmation: host.name, kind: "apply_all_updates" }
      end.to change(Servers::Action, :count).by(1)
      expect(Servers::Action.last.kind).to eq("apply_all_updates")
    end

    # Senza questo gate l'azione verrebbe accodata e l'agent la rifiuterebbe ("tipo azione non
    # supportato"), occupando l'unica slot attiva per host.
    it "non accoda un'azione che l'agent installato non conosce" do
      host.update!(agent_version: "0.7.0")
      sign_in(owner)

      expect do
        post member_monitoring_server_actions_path(host),
             params: { confirm: "1", confirmation: host.name, kind: "apply_all_updates" }
      end.not_to change(Servers::Action, :count)
      expect(flash[:alert]).to eq(I18n.t("member.servers.action_queue.agent_upgrade_required"))
    end

    it "gli aggiornamenti di sicurezza restano accodabili anche sugli agent vecchi" do
      host.update!(agent_version: "0.4.0")
      sign_in(owner)

      expect do
        post member_monitoring_server_actions_path(host),
             params: { confirm: "1", confirmation: host.name, kind: "apply_security_updates" }
      end.to change(Servers::Action, :count).by(1)
    end

    it "annulla soltanto un'azione queued dello stesso host" do
      action = create(:server_action, host:, organization:)
      sign_in(owner)
      delete member_monitoring_server_action_path(host, action), params: { confirm: "1" }
      expect(action.reload).to be_status_cancelled
    end
  end
  # CYRA-489 — l'elenco dei container che su questa macchina non sono servizi: senza, l'unica difesa
  # contro gli avvisi sul lavoro normale delle build era spegnere l'intera regola.
  describe "container che non sono servizi" do
    it "il modulo mostra e salva l'elenco" do
      host = create(:server_host, organization: organization, ignored_container_patterns: [ "ci-runner" ])
      sign_in(owner)

      get edit_member_monitoring_server_path(host)
      expect(response.body).to include('data-test="server-ignored-containers-field"')
      expect(response.body).to include("ci-runner")

      patch member_monitoring_server_path(host), params: { confirm: "1", name: host.name, ignored_container_patterns: "ci-runner\ntest-postgres" }

      expect(host.reload.ignored_container_patterns).to eq(%w[ci-runner test-postgres])
    end

    it "un frammento troppo corto non passa" do
      host = create(:server_host, organization: organization)
      sign_in(owner)

      patch member_monitoring_server_path(host), params: { name: host.name, ignored_container_patterns: "ab" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(host.reload.ignored_container_patterns).to be_empty
    end
  end
  # CYRA-678 — gemello del blocco container per le unit systemd rumorose.
  describe "servizi da non avvisare" do
    it "il modulo mostra e salva l'elenco" do
      host = create(:server_host, organization: organization, ignored_service_patterns: [ "motd-news" ])
      sign_in(owner)

      get edit_member_monitoring_server_path(host)
      expect(response.body).to include('data-test="server-ignored-services-field"')
      expect(response.body).to include("motd-news")

      patch member_monitoring_server_path(host), params: { confirm: "1", name: host.name, ignored_service_patterns: "motd-news\nfwupd-refresh" }

      expect(host.reload.ignored_service_patterns).to eq(%w[motd-news fwupd-refresh])
    end

    it "un frammento troppo corto non passa" do
      host = create(:server_host, organization: organization)
      sign_in(owner)

      patch member_monitoring_server_path(host), params: { name: host.name, ignored_service_patterns: "ab" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(host.reload.ignored_service_patterns).to be_empty
    end
  end
  # CYRA-467 — italiano e inglese nella stessa colonna, plurali sbagliati («1 updates») e gergo
  # tecnico grezzo proprio dove sta l'informazione più utile.
  describe "il blocco del database si legge" do
    it "gli stati delle connessioni sono scritti a parole, col nome tecnico nel tooltip" do
      host = create(:server_host, organization: organization,
                                  database_snapshot: { "reachable" => true,
                                                       "connections" => { "total" => 12, "max" => 100,
                                                                          "by_state" => { "idle_in_transaction" => 3, "active" => 9 } } })
      sign_in(owner)

      get member_monitoring_server_path(host, tab: "hardware")

      chip = Nokogiri::HTML(response.body).css('[data-test="server-database-state"]')
      expect(chip.map(&:text).join).to include(I18n.t("member.servers.show.connection_states.idle_in_transaction"))
      expect(chip.map { |node| node["title"] }).to include("idle_in_transaction")
    end

    it "il plurale dei pacchetti è corretto" do
      expect(I18n.t("member.servers.show.updates_count", count: 1, locale: :it)).to eq("1 pacchetto")
      expect(I18n.t("member.servers.show.updates_count", count: 3, locale: :it)).to eq("3 pacchetti")
    end

    # CYRA-329 chiedeva che l'area non avesse due nomi diversi (uno nello switcher, uno nel menu).
    # Con CYRA-521 lo switcher non esiste più e il nome è uno solo per costruzione: resta da difendere
    # che ci sia, e che sia in italiano come il resto dell'interfaccia.
    it "l'area ha un nome solo, in italiano" do
      nome = I18n.t("member.nav.group_infrastructure", locale: :it)

      expect(nome).to eq("Infrastruttura")
    end
  end
end
