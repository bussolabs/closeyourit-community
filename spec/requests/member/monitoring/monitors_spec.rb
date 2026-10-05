# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::Monitors", type: :request do
  let(:org) { create(:organization) }
  # Gli attori nascono con la loro membership solo quando un esempio li nomina (CYRA-551): quasi
  # ogni esempio ne usa uno, e un `before` comune li faceva pagare tutti a tutti.
  let(:owner) { account_with_membership(:owner) }
  let(:admin) { account_with_membership(:admin) }
  let(:member) { account_with_membership(:member) }
  # Progetto uptime-capable (ha una piattaforma web/server): l'uptime esiste solo su questi.
  let(:project) do
    create(:project, organization: org).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }

  def account_with_membership(role)
    create(:account).tap { |account| create(:membership, account: account, organization: org, role: role) }
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def declared_monitor(**attrs)
    create(:uptime_monitor, project:, environment:, **attrs)
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_monitoring_monitors_path
      expect(response).to redirect_to(login_path)
    end

    it "admin → 200 e vede i monitor dell'org" do
      sign_in(owner)
      declared_monitor(url: "https://store.test/up")
      get member_monitoring_monitors_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("https://store.test/up")
    end

    # T10 — the footer of the list names the colours of the availability strip, grey included.
    it "explains the colours of the availability strip under the list" do
      sign_in(owner)
      declared_monitor(url: "https://store.test/up")
      get member_monitoring_monitors_path

      legend = Capybara.string(response.body).find("[data-test='monitors-strip-legend']")
      %w[up partial down no_data].each { |key| expect(legend).to have_text(I18n.t("member.uptime.bucket.#{key}")) }
    end

    # CYRA-477: la stessa indicazione di copertura dei cron compare sull'elenco dei siti sotto controllo.
    it "senza regola uptime_down mostra il banner di copertura e il link per crearla" do
      sign_in(owner)
      declared_monitor(url: "https://store.test/up")

      get member_monitoring_monitors_path

      expect(response.body).to include('data-test="monitors-coverage-link"')
      expect(response.body).to include("event_type=uptime_down")
      # A floating notice, yellow: something to fix. The key carries the state, so it comes back on a change.
      notice = Nokogiri::HTML(response.body).at_css('[data-test="monitors-coverage"]')
      expect(notice["data-ui--floating-notice-key-value"]).to eq("coverage_uptime:uncovered-1")
      expect(notice["class"]).to include("bg-amber-50")
    end

    it "la project key nella riga monitor non è più indigo (dato statico, One-Voice)" do
      sign_in(owner)
      declared_monitor(url: "https://store.test/up")
      get member_monitoring_monitors_path
      row = Nokogiri::HTML(response.body).at_css('[data-test="monitor-row"]')
      expect(row.text).to include(project.key)
      expect(row.css("span.text-indigo-600").map(&:text)).not_to include(project.key)
    end

    it "member assegnato vede i monitor del progetto, non di un altro (BOLA)" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      declared_monitor(url: "https://visible.test/up")
      other = create(:project, organization: org)
      oenv = create(:environment, organization: org).tap { |e| other.environments << e }
      create(:uptime_monitor, project: other, environment: oenv, url: "https://hidden.test/up")
      get member_monitoring_monitors_path
      expect(response.body).to include("visible.test")
      expect(response.body).not_to include("hidden.test")
    end

    it "filtra per status" do
      sign_in(owner)
      declared_monitor(url: "https://up.test/x", current_status: :up)
      env2 = create(:environment, organization: org).tap { |e| project.environments << e }
      create(:uptime_monitor, project:, environment: env2, url: "https://down.test/x", current_status: :down)
      get member_monitoring_monitors_path, params: { status: [ "down" ] }
      expect(response.body).to include("down.test")
      expect(response.body).not_to include("up.test")
    end

    it "filtra per progetto (param project_id)" do
      sign_in(owner)
      declared_monitor(url: "https://keep.test/x")
      other = create(:project, organization: org).tap do |p|
        p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
      end
      oenv = create(:environment, organization: org).tap { |e| other.environments << e }
      create(:uptime_monitor, project: other, environment: oenv, url: "https://drop.test/x")
      get member_monitoring_monitors_path, params: { project_id: [ project.id ] }
      expect(response.body).to include("keep.test")
      expect(response.body).not_to include("drop.test")
    end

    it "accetta un range valido dal selettore (?range=7d)" do
      sign_in(owner)
      declared_monitor(url: "https://range.test/x")
      get member_monitoring_monitors_path, params: { range: "7d" }
      expect(response).to have_http_status(:ok)
    end

    it "il filtro per stato segue lo stato mostrato: 'unknown' include il dato vecchio, 'up' lo esclude (CYRA-209)" do
      sign_in(owner)
      travel_to(Time.utc(2026, 6, 26, 12)) do
        declared_monitor(url: "https://fresh.test/up", current_status: :up, last_checked_at: 30.seconds.ago)
        env2 = create(:environment, organization: org).tap { |e| project.environments << e }
        create(:uptime_monitor, project:, environment: env2, url: "https://stale.test/up",
                                current_status: :up, last_checked_at: 1.hour.ago)

        get member_monitoring_monitors_path, params: { status: [ "unknown" ] }
        expect(response.body).to include("stale.test")
        expect(response.body).not_to include("fresh.test")

        get member_monitoring_monitors_path, params: { status: [ "up" ] }
        expect(response.body).to include("fresh.test")
        expect(response.body).not_to include("stale.test")
      end
    end

    it "il dato vecchio (worker fermo) non conta come up e la riga lo mostra Unknown (CYRA-209)" do
      sign_in(owner)
      travel_to(Time.utc(2026, 6, 26, 12)) do
        declared_monitor(url: "https://fresh.test/up", current_status: :up, last_checked_at: 30.seconds.ago)
        env2 = create(:environment, organization: org).tap { |e| project.environments << e }
        create(:uptime_monitor, project:, environment: env2, url: "https://stale.test/up",
                                current_status: :up, last_checked_at: 1.hour.ago)

        get member_monitoring_monitors_path

        expect(response).to have_http_status(:ok)
        # Conteggio "up" dell'header: solo il monitor fresco, non lo stale (che sarebbe un verde ingannevole).
        up_chip = Nokogiri::HTML(response.body).at_css('[data-test="stat-up"]')
        expect(up_chip.text).to include("1")
        # Lo stale è mostrato "Unknown" nella lista.
        expect(response.body).to include("Unknown")
      end
    end

    # CYRA-492 — «da quanto?» è la prima domanda durante un guasto: l'elenco deve rispondere senza aprire
    # la pagina del monitor.
    describe "durata del guasto, contatori-filtro e non sani per primi" do
      it "un sito giù racconta da quanto dura il guasto, non solo l'ora dell'ultimo controllo" do
        sign_in(owner)
        travel_to(Time.utc(2026, 6, 26, 12)) do
          monitor = declared_monitor(url: "https://down.test/x", current_status: :down, last_checked_at: 30.seconds.ago)
          create(:uptime_incident, monitor:, started_at: 3.hours.ago - 9.minutes)

          get member_monitoring_monitors_path

          cell = Nokogiri::HTML(response.body).at_css('[data-test="monitor-down-since"]')
          expect(cell).to be_present
          expect(cell.text).to include(I18n.t("member.uptime.down_since", duration: "3h 09m"))
        end
      end

      # F093 — the row of a site that is down says why, without opening it.
      it "a down site says why on its row, from the latest failed check" do
        sign_in(owner)
        monitor = declared_monitor(url: "https://down.test/x", current_status: :down, last_checked_at: 30.seconds.ago)
        create(:uptime_incident, monitor:, started_at: 1.hour.ago)
        create(:uptime_check, :down, monitor:, error: "old reason", checked_at: 50.minutes.ago)
        create(:uptime_check, monitor:, up: false, status_code: 503, error: nil, response_time_ms: nil, checked_at: 1.minute.ago)
        staging = create(:environment, organization: org).tap { |e| project.environments << e }
        healthy = declared_monitor(environment: staging, url: "https://up.test/x", current_status: :up, last_checked_at: 30.seconds.ago)

        get member_monitoring_monitors_path

        html = Capybara.string(response.body)
        expect(html.find("##{ActionView::RecordIdentifier.dom_id(monitor)} [data-test='monitor-down-cause']").text).to eq("HTTP 503")
        expect(html).to have_no_css("##{ActionView::RecordIdentifier.dom_id(healthy)} [data-test='monitor-down-cause']")
      end

      it "i contatori su/giù dell'header sono link ai filtri dell'elenco" do
        sign_in(owner)
        declared_monitor(url: "https://x.test/up", current_status: :up)

        get member_monitoring_monitors_path

        doc = Nokogiri::HTML(response.body)
        down_chip = doc.at_css('[data-test="stat-down"]')
        expect(down_chip.name).to eq("a")
        expect(down_chip["href"]).to eq(member_monitoring_monitors_path(status: "down"))
        expect(doc.at_css('[data-test="stat-up"]')["href"]).to eq(member_monitoring_monitors_path(status: "up"))
      end

      it "il contatore del filtro in vigore è marcato (aria-current)" do
        sign_in(owner)
        declared_monitor(url: "https://x.test/down", current_status: :down)

        get member_monitoring_monitors_path(status: "down")

        expect(Nokogiri::HTML(response.body).at_css('[data-test="stat-down"]')["aria-current"]).to eq("true")
      end

      it "nella tabella i siti non sani sono elencati per primi, anche contro l'ordine alfabetico" do
        sign_in(owner)
        travel_to(Time.utc(2026, 6, 26, 12)) do
          env2 = create(:environment, organization: org).tap { |e| project.environments << e }
          declared_monitor(name: "Alfa", url: "https://alfa.test/x", current_status: :up, last_checked_at: 30.seconds.ago)
          create(:uptime_monitor, project:, environment: env2, name: "Zeta", url: "https://zeta.test/x",
                                  current_status: :down, last_checked_at: 30.seconds.ago)

          get member_monitoring_monitors_path(view: "table")

          rows = Nokogiri::HTML(response.body).css('[data-test="monitor-row"]')
          expect(rows.first.text).to include("zeta.test")
          expect(rows.last.text).to include("alfa.test")
        end
      end

      it "dichiara sull'intestazione l'ordinamento per salute (default), non quando si ordina per colonna" do
        sign_in(owner)
        declared_monitor(url: "https://x.test/up")

        get member_monitoring_monitors_path(view: "table")
        expect(response.body).to include(I18n.t("member.uptime.sort_health_hint"))

        get member_monitoring_monitors_path(view: "table", sort: "monitor")
        expect(response.body).not_to include(I18n.t("member.uptime.sort_health_hint"))
      end
    end
  end

  describe "the View menu groups the list (C62, CYRA-924)" do
    it "offers group by uptime group or none as menu links, and the active one is checked" do
      sign_in(owner)
      declared_monitor(url: "https://x.test/up")

      get member_monitoring_monitors_path(view: "table", range: "7d")

      menu = Nokogiri::HTML(response.body).at_css('[data-test="monitors-toolbar-view-menu"]')
      grouped = menu.at_css('[data-test="uptime-group-by-grouped"]')
      none = menu.at_css('[data-test="uptime-group-by-table"]')
      expect(grouped["href"]).to include("view=grouped").and include("range=7d")
      expect(none["aria-current"]).to eq("true")
      expect(grouped["aria-current"]).to be_nil
      expect(response.body).not_to include('data-test="uptime-view-toggle"')
    end

    it "saves the grouping and the period with the view" do
      sign_in(owner)

      post member_saved_views_path, params: { resource_type: "uptime", name: "Flat week", view: "table", range: "7d" }

      expect(SavedView.find_by!(name: "Flat week").filters).to eq("view" => "table", "range" => "7d")
    end
  end

  describe "GET show" do
    it "admin → 200 con config" do
      sign_in(owner)
      monitor = declared_monitor(url: "https://store.test/up")
      get member_monitoring_monitor_path(monitor)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("https://store.test/up")
    end

    # CYRA-476: il pannello "Chi viene avvisato" è sempre presente sul detail del monitor.
    describe "pannello Chi viene avvisato" do
      it "senza regola che copra il sito avverte e offre il link per crearla" do
        sign_in(owner)
        monitor = declared_monitor(url: "https://store.test/up")

        get member_monitoring_monitor_path(monitor)

        expect(response.body).to include('data-test="monitor-alert-coverage"')
        expect(response.body).to include('data-test="monitor-alert-coverage-empty"')
        expect(response.body).to include('data-test="monitor-alert-coverage-link"')
        expect(response.body).to include("event_type=uptime_down")
      end

      it "con una regola che copre il sito la mostra e la rende apribile con un clic" do
        sign_in(owner)
        monitor = declared_monitor(url: "https://store.test/up")
        rule = create(:alerting_rule, :uptime_down, organization: org, name: "Produzione giù")

        get member_monitoring_monitor_path(monitor)

        expect(response.body).to include('data-test="monitor-alert-coverage"')
        expect(response.body).not_to include('data-test="monitor-alert-coverage-empty"')
        expect(response.body).to include("Produzione giù")
        expect(response.body).to include(member_alerting_rule_path(rule))
      end

      it "chi non gestisce gli avvisi vede il pannello ma senza il link di creazione" do
        sign_in(member)
        create(:project_membership, account: member, project:)
        monitor = declared_monitor(url: "https://store.test/up")

        get member_monitoring_monitor_path(monitor)

        expect(response.body).to include('data-test="monitor-alert-coverage"')
        expect(response.body).not_to include('data-test="monitor-alert-coverage-link"')
      end
    end

    it "monitor non visibile → 404 (BOLA)" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      foreign_p = create(:project, organization: org)
      fenv = create(:environment, organization: org).tap { |e| foreign_p.environments << e }
      foreign = create(:uptime_monitor, project: foreign_p, environment: fenv)
      get member_monitoring_monitor_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "più incident narrati con timeline: 200 senza N+1 (updates/children preloadati)" do
      sign_in(owner)
      monitor = declared_monitor(url: "https://store.test/up")
      # Incident narrati STORICI (risolti): un solo incident aperto per monitor è ora un invariante DB
      # (CYRA-269), quindi le finestre passate portano un resolved_at.
      2.times do |i|
        inc = create(:uptime_incident, monitor:, phase: :monitoring,
                     started_at: (i + 1).hours.ago, resolved_at: (i + 1).hours.ago + 20.minutes)
        create(:uptime_incident_update, incident: inc, phase: :detected)
        create(:uptime_incident, monitor:, parent: inc,
               started_at: (i + 2).hours.ago, resolved_at: (i + 2).hours.ago + 10.minutes) # figlio (window unione)
      end
      get member_monitoring_monitor_path(monitor)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="incident-timeline"')
      # picker ungroup: dialog con la scelta della finestra che tiene lo status
      expect(response.body).to include('data-test="incident-ungroup-dialog"')
      expect(response.body).to include('name="keep_incident_id"')
    end

    it "range=1y → 365 barre giornaliere dai rollup daily (vista annuale)" do
      sign_in(owner)
      monitor = declared_monitor(url: "https://store.test/up")
      create(:uptime_check, :daily, monitor:, checked_at: 10.days.ago.beginning_of_day)
      create(:uptime_check, :daily, monitor:, checked_at: 20.days.ago.beginning_of_day)

      get member_monitoring_monitor_path(monitor, range: "1y")

      expect(response).to have_http_status(:ok)
      bars = Nokogiri::HTML(response.body).css('[data-test="uptime-buckets"] > span')
      expect(bars.size).to eq(365)
    end

    it "la timeline non veicola lo stato solo col colore: striscia aria-hidden + riassunto sr-only" do
      sign_in(owner)
      monitor = declared_monitor(url: "https://store.test/up")
      get member_monitoring_monitor_path(monitor)

      doc = Nokogiri::HTML(response.body)
      strip = doc.at_css('[data-test="uptime-buckets"]')
      expect(strip["aria-hidden"]).to eq("true")
      summary = doc.at_css('[data-test="uptime-buckets-summary"]')
      expect(summary).to be_present
      expect(summary["class"]).to include("sr-only")
      expect(summary.text).to be_present
    end

    it "riassunto sr-only: un solo blocco parziale → «1 parziale» al singolare" do
      owner.update!(locale: "it")
      sign_in(owner)
      monitor = declared_monitor(url: "https://store.test/up")
      create(:uptime_check, monitor: monitor, up: true, checked_at: 5.minutes.ago)
      create(:uptime_check, monitor: monitor, up: false, checked_at: 4.minutes.ago)
      get member_monitoring_monitor_path(monitor, range: "24h")

      summary = Nokogiri::HTML(response.body).at_css('[data-test="uptime-buckets-summary"]').text
      expect(summary).to include("1 parziale,")
      expect(summary).not_to include("1 parziali")
    end

    it "Tentativi recenti: con molti check ne mostra al massimo 10 (i più recenti) e la label è coerente" do
      sign_in(owner)
      monitor = declared_monitor(url: "https://store.test/up")
      # 12 check raw > 10: senza il cap la lista ne mostrerebbe più di 10.
      12.times { |i| create(:uptime_check, monitor:, checked_at: (i + 1).minutes.ago) }

      get member_monitoring_monitor_path(monitor)

      expect(response).to have_http_status(:ok)
      rows = Nokogiri::HTML(response.body).css('[data-test="monitor-check-row"]')
      expect(rows.size).to eq(10)
      # Label conteggio coerente con le righe mostrate (10, non 12).
      expect(response.body).to include(I18n.t("member.uptime.last_checks", count: 10))
      expect(response.body).not_to include(I18n.t("member.uptime.last_checks", count: 12))
    end

    it "Tentativi recenti: sotto le 10 righe le mostra tutte con label coerente" do
      sign_in(owner)
      monitor = declared_monitor(url: "https://store.test/up")
      3.times { |i| create(:uptime_check, monitor:, checked_at: (i + 1).minutes.ago) }

      get member_monitoring_monitor_path(monitor)

      rows = Nokogiri::HTML(response.body).css('[data-test="monitor-check-row"]')
      expect(rows.size).to eq(3)
      expect(response.body).to include(I18n.t("member.uptime.last_checks", count: 3))
    end

    # CYRA-495 — chi naviga a lettore di schermo deve poter distinguere una riga dall'altra: la casella
    # di selezione non aveva nome proprio (il lettore ripiega sul value, cioè l'UUID) e il comando di
    # gestione si ripeteva identico su ogni riga. Ora entrambi nominano l'inizio della finestra.
    it "casella e comando di ogni incident nominano la data della riga, non il suo identificativo (CYRA-495)" do
      sign_in(owner)
      monitor = declared_monitor(url: "https://store.test/up")
      # Un solo incident aperto per monitor è invariante DB (CYRA-269): le due finestre sono risolte.
      first = create(:uptime_incident, monitor:, started_at: 3.hours.ago, resolved_at: 2.hours.ago)
      second = create(:uptime_incident, monitor:, started_at: 90.minutes.ago, resolved_at: 30.minutes.ago)

      get member_monitoring_monitor_path(monitor)

      doc = Nokogiri::HTML(response.body)
      [ first, second ].each do |incident|
        # Finestre non raggruppate: l'inizio della finestra unione coincide con lo started_at, che si
        # legge senza toccare i figli (window_started_at qui li interrogherebbe, insospettendo Prosopite).
        started = I18n.l(incident.started_at, format: :short)
        row = doc.at_css(%([data-incident-id="#{incident.id}"]))
        checkbox = row.at_css('[data-test="incident-select"]')
        expect(checkbox["aria-label"]).to eq(I18n.t("member.uptime.incident.select_row", started_at: started))
        expect(checkbox["aria-label"]).not_to include(incident.id)
        manage = doc.at_css(%([data-test="incident-manage-#{incident.id}"]))
        expect(manage["aria-label"]).to eq(I18n.t("member.uptime.incident.manage_row", started_at: started))
        expect(manage["aria-label"]).not_to include(incident.id)
      end

      # Due righe, due nomi diversi: i comandi non si chiamano più tutti allo stesso modo.
      labels = [ first, second ].map { |i| doc.at_css(%([data-test="incident-manage-#{i.id}"]))["aria-label"] }
      expect(labels.uniq.size).to eq(2)
    end
  end

  describe "GET new / POST create" do
    it "admin new → 200" do
      sign_in(owner)
      environment
      get new_member_monitoring_monitor_path
      expect(response).to have_http_status(:ok)
    end

    it "new?project_id=X: il select environment elenca SOLO gli environment del progetto X" do
      sign_in(owner)
      env_x = environment # dichiarato su `project` (X)
      other = create(:project, organization: org).tap do |p|
        p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
      end
      env_y = create(:environment, organization: org).tap { |e| other.environments << e }
      get new_member_monitoring_monitor_path, params: { project_id: project.id }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("monitor_environment_field") # turbo frame target
      expect(response.body).to include(env_x.id)
      expect(response.body).not_to include(env_y.id)
      # wiring JS: il select Project ricarica il frame al change (punto fragile = nomi data-attribute)
      expect(response.body).to include('data-controller="monitoring--environment-loader"')
      expect(response.body).to include("change-&gt;monitoring--environment-loader#reload").or include("change->monitoring--environment-loader#reload")
      expect(response.body).to include("data-monitoring--environment-loader-frame-value=\"monitor_environment_field\"")
    end

    it "new senza project_id: select environment vuoto + hint per scegliere il progetto" do
      sign_in(owner)
      env_x = environment
      get new_member_monitoring_monitor_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(env_x.id) # nessun environment finché non si sceglie il progetto
      expect(response.body).to include(I18n.t("member.uptime.form.project_required"))
    end

    it "membro semplice → redirect (forbidden)" do
      sign_in(member)
      get new_member_monitoring_monitor_path
      expect(response).to redirect_to(root_path)
    end

    it "admin crea un monitor (project+env dichiarato), senza name → name auto-derivato" do
      sign_in(owner)
      env = environment
      # NB: il form reale NON invia name (non ha quel campo) → name dev'essere derivato server-side.
      expect do
        post member_monitoring_monitors_path, params: {
          project_id: project.id, environment_id: env.id,
          url: "https://store.test/up", http_method: "GET", interval_seconds: 60,
          expected_status: 200, timeout_seconds: 5
        }
      end.to change(Uptime::Monitor, :count).by(1)
      monitor = Uptime::Monitor.last
      expect(monitor.environment).to eq(env)
      expect(monitor.created_by).to eq(owner)
      expect(monitor.name).to eq("#{project.name} · #{env.label}")
      expect(response).to redirect_to(member_monitoring_monitor_path(monitor))
    end

    it "admin crea un monitor con keyword e soglia ssl (params esatti del form)" do
      sign_in(owner)
      env = environment
      post member_monitoring_monitors_path, params: {
        project_id: project.id, environment_id: env.id,
        url: "https://store.test/up", http_method: "GET", interval_seconds: 60,
        expected_status: 200, timeout_seconds: 5,
        expected_body_keyword: "healthy", ssl_expiry_warn_days: 14
      }
      monitor = Uptime::Monitor.last
      expect(monitor.expected_body_keyword).to eq("healthy")
      expect(monitor.ssl_expiry_warn_days).to eq(14)
    end

    it "crea un monitor TCP (porta) con host e porta, senza url (CYRA-151)" do
      sign_in(owner)
      env = environment
      expect do
        post member_monitoring_monitors_path, params: {
          project_id: project.id, environment_id: env.id,
          check_type: "tcp", host: "db.store.test", port: 5432,
          interval_seconds: 60, timeout_seconds: 5
        }
      end.to change(Uptime::Monitor, :count).by(1)
      monitor = Uptime::Monitor.last
      expect(monitor.check_type).to eq("tcp")
      expect(monitor.host).to eq("db.store.test")
      expect(monitor.port).to eq(5432)
      expect(monitor.url).to be_blank
    end

    it "salva la soglia di latenza del monitor (CYRA-151)" do
      sign_in(owner)
      env = environment
      post member_monitoring_monitors_path, params: {
        project_id: project.id, environment_id: env.id,
        url: "https://store.test/up", http_method: "GET", interval_seconds: 60,
        expected_status: 200, timeout_seconds: 5, latency_threshold_ms: 800
      }
      expect(Uptime::Monitor.last.latency_threshold_ms).to eq(800)
    end

    it "assegna il monitor a un gruppo uptime (param group_id)" do
      sign_in(owner)
      env = environment
      group = create(:uptime_group, organization: org)
      post member_monitoring_monitors_path, params: {
        project_id: project.id, environment_id: env.id, group_id: group.id,
        url: "https://store.test/up", http_method: "GET", interval_seconds: 60,
        expected_status: 200, timeout_seconds: 5
      }
      expect(Uptime::Monitor.last.group).to eq(group)
    end

    it "ignora un group_id di un'altra organizzazione (anti-BOLA: nessun gruppo)" do
      sign_in(owner)
      env = environment
      altrui = create(:uptime_group, organization: create(:organization))
      post member_monitoring_monitors_path, params: {
        project_id: project.id, environment_id: env.id, group_id: altrui.id,
        url: "https://store.test/up", http_method: "GET", interval_seconds: 60,
        expected_status: 200, timeout_seconds: 5
      }
      expect(Uptime::Monitor.last.group).to be_nil
    end

    it "environment non dichiarato dal progetto → 422" do
      sign_in(owner)
      undeclared = create(:environment, organization: org)
      expect do
        post member_monitoring_monitors_path, params: {
          project_id: project.id, environment_id: undeclared.id, name: "X",
          url: "https://x.test/up", interval_seconds: 60, expected_status: 200, timeout_seconds: 5
        }
      end.not_to change(Uptime::Monitor, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "duplicato [progetto, environment] → 422 con errore visibile (non muto)" do
      sign_in(owner)
      env = environment
      declared_monitor(url: "https://first.test/up") # occupa [project, env]
      expect do
        post member_monitoring_monitors_path, params: {
          project_id: project.id, environment_id: env.id, name: "Dup",
          url: "https://second.test/up", http_method: "GET", interval_seconds: 60,
          expected_status: 200, timeout_seconds: 5
        }
      end.not_to change(Uptime::Monitor, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("monitor-errors")
      expect(response.body).to include("already has a monitor for this project")
    end

    it "membro semplice → niente creato" do
      sign_in(member)
      env = environment
      expect do
        post member_monitoring_monitors_path, params: { project_id: project.id, environment_id: env.id, url: "https://x.test/up" }
      end.not_to change(Uptime::Monitor, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "PATCH update" do
    it "admin aggiorna le impostazioni (url/interval)" do
      sign_in(owner)
      monitor = declared_monitor(url: "https://old.test/up", interval_seconds: 60)
      patch member_monitoring_monitor_path(monitor), params: { url: "https://new.test/up", interval_seconds: 120, http_method: "GET", expected_status: 200, timeout_seconds: 5, name: monitor.name }
      expect(monitor.reload.url).to eq("https://new.test/up")
      expect(monitor.interval_seconds).to eq(120)
    end

    # CYRA-776: la soglia di conferma si regola dalla scheda del monitor (default 2).
    it "admin regola la soglia di controlli falliti prima dell'avviso" do
      sign_in(owner)
      monitor = declared_monitor(url: "https://old.test/up")
      expect(monitor.failure_threshold).to eq(2)
      patch member_monitoring_monitor_path(monitor),
            params: { url: monitor.url, http_method: "GET", interval_seconds: 60, expected_status: 200,
                      timeout_seconds: 5, failure_threshold: 3 }
      expect(monitor.reload.failure_threshold).to eq(3)
    end

    it "soglia di conferma fuori range → 422, soglia invariata" do
      sign_in(owner)
      monitor = declared_monitor(url: "https://old.test/up")
      patch member_monitoring_monitor_path(monitor),
            params: { url: monitor.url, http_method: "GET", interval_seconds: 60, expected_status: 200,
                      timeout_seconds: 5, failure_threshold: 0 }
      expect(response).to have_http_status(:unprocessable_content)
      expect(monitor.reload.failure_threshold).to eq(2)
    end

    it "update invalido (url vuoto) → ri-renderizza il form 422, url invariato" do
      sign_in(owner)
      monitor = declared_monitor(url: "https://old.test/up")
      patch member_monitoring_monitor_path(monitor),
            params: { url: "", http_method: "GET", interval_seconds: 60, expected_status: 200, timeout_seconds: 5 }
      expect(response).to have_http_status(:unprocessable_content)
      expect(monitor.reload.url).to eq("https://old.test/up")
    end

    it "cambia e poi rimuove il gruppo del monitor (group_id mutabile)" do
      sign_in(owner)
      monitor = declared_monitor(url: "https://old.test/up")
      group = create(:uptime_group, organization: org)
      patch member_monitoring_monitor_path(monitor),
            params: { url: monitor.url, http_method: "GET", interval_seconds: 60, expected_status: 200, timeout_seconds: 5, group_id: group.id }
      expect(monitor.reload.group).to eq(group)
      patch member_monitoring_monitor_path(monitor),
            params: { url: monitor.url, http_method: "GET", interval_seconds: 60, expected_status: 200, timeout_seconds: 5, group_id: "" }
      expect(monitor.reload.group).to be_nil
    end
  end

  describe "DELETE destroy" do
    it "admin elimina il monitor" do
      sign_in(owner)
      monitor = declared_monitor
      expect { delete member_monitoring_monitor_path(monitor) }.to change(Uptime::Monitor, :count).by(-1)
      expect(response).to redirect_to(member_monitoring_monitors_path)
    end
  end

  describe "pause / resume" do
    it "admin mette in pausa e riprende" do
      sign_in(owner)
      monitor = declared_monitor(active: true)
      patch pause_member_monitoring_monitor_path(monitor)
      expect(monitor.reload.active).to be(false)
      patch resume_member_monitoring_monitor_path(monitor)
      expect(monitor.reload.active).to be(true)
    end

    it "membro semplice → forbidden" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      monitor = declared_monitor(active: true)
      patch pause_member_monitoring_monitor_path(monitor)
      expect(monitor.reload.active).to be(true)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "publish / unpublish (status page pubblica opt-in)" do
    it "admin pubblica e ritira la status page pubblica del monitor" do
      sign_in(owner)
      monitor = declared_monitor(public_status_enabled: false)
      patch publish_member_monitoring_monitor_path(monitor)
      expect(monitor.reload.public_status_enabled).to be(true)
      patch unpublish_member_monitoring_monitor_path(monitor)
      expect(monitor.reload.public_status_enabled).to be(false)
    end

    it "membro semplice → forbidden, flag invariato" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      monitor = declared_monitor(public_status_enabled: false)
      patch publish_member_monitoring_monitor_path(monitor)
      expect(monitor.reload.public_status_enabled).to be(false)
      expect(response).to redirect_to(root_path)
    end

    it "monitor non visibile → 404 (BOLA)" do
      sign_in(member)
      create(:project_membership, account: member, project:)
      foreign_p = create(:project, organization: org)
      fenv = create(:environment, organization: org).tap { |e| foreign_p.environments << e }
      foreign = create(:uptime_monitor, project: foreign_p, environment: fenv)
      patch publish_member_monitoring_monitor_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "non autenticato → redirect login, flag invariato" do
      monitor = declared_monitor(public_status_enabled: false)
      patch publish_member_monitoring_monitor_path(monitor)
      expect(response).to redirect_to(login_path)
      expect(monitor.reload.public_status_enabled).to be(false)
    end

    it "la show mostra il link pubblico copiabile solo quando pubblicato" do
      sign_in(owner)
      monitor = declared_monitor(public_status_enabled: true)
      get member_monitoring_monitor_path(monitor, tab: "public")
      expect(response.body).to include(
        public_status_path(org.slug, project.key, environment.code)
      )
    end

    it "la show NON mostra il link pubblico quando il monitor non è pubblicato" do
      sign_in(owner)
      monitor = declared_monitor(public_status_enabled: false)
      get member_monitoring_monitor_path(monitor, tab: "public")
      expect(response.body).not_to include(
        public_status_path(org.slug, project.key, environment.code)
      )
    end

    it "pubblicato → la show offre i due codici da incollare (riquadro e pagina intera)" do
      sign_in(owner)
      monitor = declared_monitor(public_status_enabled: true)
      get member_monitoring_monitor_path(monitor, tab: "public")

      expect(response.body).to include('data-test="monitor-embed"')
      expect(response.body).to include('data-test="monitor-embed-dialog"')
      # Gli snippet sono testo da copiare, quindi nel body arrivano ESCAPATI.
      expect(response.body).to include(ERB::Util.html_escape(
        %(<iframe src="#{public_status_badge_url(org.slug, project.key, environment.code)}" width="280" height="36")
      ))
      expect(response.body).to include(ERB::Util.html_escape(
        %(<iframe src="#{public_status_url(org.slug, project.key, environment.code)}" width="100%" height="800")
      ))
    end

    it "i due snippet stanno in scope clipboard SEPARATI (altrimenti si copierebbero a vicenda)" do
      sign_in(owner)
      monitor = declared_monitor(public_status_enabled: true)
      get member_monitoring_monitor_path(monitor, tab: "public")

      doc = Nokogiri::HTML(response.body)
      %w[monitor-embed-badge monitor-embed-page].each do |block|
        node = doc.at_css(%([data-test="#{block}"]))
        expect(node["data-controller"]).to eq("clipboard")
        expect(node.css('[data-clipboard-target="source"]').size).to eq(1)
      end
    end

    it "in italiano la lingua finisce SOLO negli snippet: il link da condividere resta pulito" do
      owner.update!(locale: "it")
      sign_in(owner)
      monitor = declared_monitor(public_status_enabled: true)
      get member_monitoring_monitor_path(monitor, tab: "public")

      page_url = public_status_url(org.slug, project.key, environment.code)
      # Il link mostrato/copiato è quello di sempre, senza parametri…
      expect(Nokogiri::HTML(response.body).at_css('[data-test="monitor-public-open"]')["href"]).to eq(page_url)
      # …mentre gli snippet inchiodano la lingua, così il sito di destinazione parla italiano.
      expect(response.body).to include(ERB::Util.html_escape(%(src="#{page_url}?locale=it")))
      expect(response.body).to include(ERB::Util.html_escape(
        %(src="#{public_status_badge_url(org.slug, project.key, environment.code)}?locale=it")
      ))
    end

    it "NON pubblicato → nessun pulsante Incorpora" do
      sign_in(owner)
      monitor = declared_monitor(public_status_enabled: false)
      get member_monitoring_monitor_path(monitor, tab: "public")
      expect(response.body).not_to include('data-test="monitor-embed"')
    end

    it "chi non può gestire l'uptime non vede il pulsante Incorpora" do
      sign_in(member)
      monitor = declared_monitor(public_status_enabled: true)
      get member_monitoring_monitor_path(monitor, tab: "public")
      expect(response.body).not_to include('data-test="monitor-embed"')
    end
  end

  describe "gating uptime sui progetti solo-mobile (capability piattaforma)" do
    let(:native_project) do
      create(:project, organization: org).tap do |p|
        p.project_platforms.create!(platform: create(:platform, organization: org)) # nativa (no uptime)
      end
    end
    let(:native_env) { create(:environment, organization: org).tap { |e| native_project.environments << e } }

    it "il form new elenca solo i progetti uptime-capable (esclude i solo-mobile)" do
      sign_in(owner)
      project          # uptime-capable (forza la creazione PRIMA della GET)
      native_project   # solo-mobile
      get new_member_monitoring_monitor_path
      expect(response.body).to include(project.id)
      expect(response.body).not_to include(native_project.id)
    end

    it "POST create su un progetto solo-mobile → 422 e nessun monitor creato" do
      sign_in(owner)
      env = native_env
      expect do
        post member_monitoring_monitors_path, params: {
          project_id: native_project.id, environment_id: env.id,
          url: "https://x.test/up", http_method: "GET", interval_seconds: 60,
          expected_status: 200, timeout_seconds: 5
        }
      end.not_to change(Uptime::Monitor, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
  # CYRA-487 — «100%» su ventiquattro ore calcolato su tre ore di dati è una dichiarazione falsa:
  # sembra «tutto a posto da un giorno» e significa «del resto non so nulla».
  describe "la copertura del periodo" do
    let(:monitor) { create(:uptime_monitor, project:) }

    before { sign_in(owner) }

    it "dichiara su quanta parte del periodo è calcolata, quando è parziale" do
      create(:uptime_check, monitor:, up: true, checked_at: 10.minutes.ago)

      get member_monitoring_monitor_path(monitor, range: "24h")

      expect(response.body).to include('data-test="uptime-coverage"')
      testo = Nokogiri::HTML(response.body).at_css('[data-test="uptime-coverage"]').text
      expect(testo).to include("24h")
    end

    it "spiega perché mancano dei periodi: raccolta iniziata dopo" do
      monitor.update_column(:created_at, 2.hours.ago)
      create(:uptime_check, monitor:, up: true, checked_at: 10.minutes.ago)

      get member_monitoring_monitor_path(monitor, range: "24h")

      nota = Nokogiri::HTML(response.body).at_css('[data-test="uptime-empty-reason"]').text
      expect(nota).to include(I18n.t("member.uptime.window_empty_reason.before_start"))
    end

    it "se il controllo esisteva già, dice che quei controlli non sono stati registrati" do
      monitor.update_column(:created_at, 10.days.ago)
      create(:uptime_check, monitor:, up: true, checked_at: 10.minutes.ago)

      get member_monitoring_monitor_path(monitor, range: "24h")

      nota = Nokogiri::HTML(response.body).at_css('[data-test="uptime-empty-reason"]').text
      expect(nota).to include(I18n.t("member.uptime.window_empty_reason.no_checks"))
    end

    it "con la copertura piena non dichiara niente" do
      cfg = Uptime::Monitor.bucket_config("30m")
      # I blocchi partono da `Time.current` DELLA RICHIESTA, non da quello della preparazione: su una
      # macchina lenta i due istanti si allontanano, il controllo più vecchio esce dalla finestra e il
      # primo blocco resta vuoto — la prova falliva a intermittenza per l'orologio, non per il codice.
      # Col tempo fermo i due istanti coincidono e la copertura è piena per costruzione.
      travel_to Time.current do
        allow_n_plus_one do
          cfg[:count].times do |i|
            create(:uptime_check, monitor:, up: true, checked_at: (i * cfg[:seconds] + 5).seconds.ago)
          end
        end

        get member_monitoring_monitor_path(monitor, range: "30m")
      end

      expect(response.body).not_to include('data-test="uptime-coverage"')
    end
  end

  # CYRA-363 — «Nessun monitor» non insegnava niente: lo stato vuoto ora dice a cosa serve, fa un
  # esempio e offre il pulsante.
  describe "lo stato vuoto insegna" do
    it "dice cosa manca, a cosa serve, un esempio e come farlo" do
      sign_in(owner)

      get member_monitoring_monitors_path

      vuoto = Nokogiri::HTML(response.body).at_css("[data-test='monitors-empty']")
      expect(vuoto).to be_present
      expect(vuoto.at_css("[data-test='empty-body']").text).to be_present
      expect(vuoto.at_css("[data-test='empty-example']").text).to include(I18n.t("member.uptime.empty_example"))
      expect(vuoto.at_css("[data-test='monitors-empty-new']")).to be_present
    end
  end
end
