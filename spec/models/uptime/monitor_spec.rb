# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Monitor, type: :model do
  describe "factory" do
    it "produce un monitor valido" do
      expect(build(:uptime_monitor)).to be_valid
    end
  end

  describe "validazioni" do
    it "rejects private HTTP destinations before the first check" do
      %w[http://localhost http://127.0.0.1 http://10.0.0.2 http://[::1] http://app.local].each do |url|
        monitor = build(:uptime_monitor, url:)
        expect(monitor).not_to be_valid
        expect(monitor.errors[:url]).to include(I18n.t("member.review_fixes.public_url_required"))
      end
    end

    it "allows pausing a legacy private monitor without changing its address" do
      monitor = create(:uptime_monitor)
      monitor.update_column(:url, "http://localhost")
      expect(monitor.update(active: false)).to be(true)
    end

    # CYRA-776 — la soglia di conferma: quanti controlli falliti di fila servono per dichiarare il
    # sito irraggiungibile. Nasce a 2 (un solo inciampo di rete non è un guasto) ed è configurabile
    # per monitor; il tetto impedisce che una cifra battuta male renda il monitor muto per ore.
    it "la soglia di conferma nasce a 2 e il contatore dei falliti a zero" do
      monitor = build(:uptime_monitor)
      expect(monitor.failure_threshold).to eq(2)
      expect(monitor.consecutive_failures).to eq(0)
    end

    it "la soglia di conferma accetta solo interi positivi entro il tetto" do
      expect(build(:uptime_monitor, failure_threshold: 0)).not_to be_valid
      expect(build(:uptime_monitor, failure_threshold: 1)).to be_valid
      expect(build(:uptime_monitor, failure_threshold: described_class::MAX_FAILURE_THRESHOLD)).to be_valid
      expect(build(:uptime_monitor, failure_threshold: described_class::MAX_FAILURE_THRESHOLD + 1)).not_to be_valid
    end

    it "richiede url; name è opzionale (auto-derivato)" do
      expect(build(:uptime_monitor, url: nil)).not_to be_valid
      expect(build(:uptime_monitor, name: nil)).to be_valid
    end

    it "deriva il name da 'progetto · environment' quando assente (il form non lo chiede)" do
      project = create(:project, name: "Storefront")
      env = create(:environment, organization: project.organization, label: "Production")
      project.environments << env
      m = create(:uptime_monitor, project:, environment: env, name: nil)
      expect(m.name).to eq("Storefront · Production")
    end

    it "senza progetto/environment non deriva il name (resta nil, invalido per altri motivi)" do
      m = Uptime::Monitor.new(url: "https://x.test/up", http_method: "GET",
                              expected_status: 200, interval_seconds: 60, timeout_seconds: 5)
      m.valid?
      expect(m.name).to be_nil
    end

    it "rifiuta url non http(s)" do
      expect(build(:uptime_monitor, url: "ftp://x")).not_to be_valid
      expect(build(:uptime_monitor, url: "not-a-url")).not_to be_valid
      expect(build(:uptime_monitor, url: "https://ok.test")).to be_valid
    end

    it "http_method solo nella whitelist (GET/HEAD/POST), normalizzato upcase" do
      expect(create(:uptime_monitor, http_method: "get").http_method).to eq("GET")
      expect(build(:uptime_monitor, http_method: "DELETE")).not_to be_valid
      expect(build(:uptime_monitor, http_method: "Net::HTTP::Get.new")).not_to be_valid
    end

    it "interval/expected/timeout devono essere > 0" do
      expect(build(:uptime_monitor, interval_seconds: 0)).not_to be_valid
      expect(build(:uptime_monitor, timeout_seconds: -1)).not_to be_valid
      expect(build(:uptime_monitor, expected_status: 0)).not_to be_valid
    end

    it "normalizza url e name (strip)" do
      m = create(:uptime_monitor, url: "  https://x.test  ", name: "  M  ")
      expect(m.url).to eq("https://x.test")
      expect(m.name).to eq("M")
    end
  end

  describe "binding all'environment (1 per [progetto, env], subset)" do
    it "richiede un environment" do
      m = build(:uptime_monitor)
      m.environment = nil
      expect(m).not_to be_valid
    end

    it "valido se l'environment è dichiarato dal progetto" do
      project = create(:project)
      env = create(:environment, organization: project.organization)
      project.environments << env
      expect(build(:uptime_monitor, project:, environment: env)).to be_valid
    end

    it "invalido se l'environment NON è dichiarato dal progetto" do
      project = create(:project)
      undeclared = create(:environment, organization: project.organization)
      expect(build(:uptime_monitor, project:, environment: undeclared)).not_to be_valid
    end

    it "invalido se l'environment è di un'altra org" do
      project = create(:project)
      other = create(:environment, organization: create(:organization))
      expect(build(:uptime_monitor, project:, environment: other)).not_to be_valid
    end

    it "un solo monitor per [progetto, environment], con messaggio leggibile" do
      project = create(:project)
      env = create(:environment, organization: project.organization)
      project.environments << env
      create(:uptime_monitor, project:, environment: env)
      dup = build(:uptime_monitor, project:, environment: env)
      expect(dup).not_to be_valid
      expect(dup.errors[:environment_id]).to include("already has a monitor for this project")
    end
  end

  describe "capability uptime del progetto (solo web/server)" do
    # Costruiti a mano (NON via factory) perché il factory rende il progetto uptime-capable.
    def monitor_for(project, env)
      Uptime::Monitor.new(project:, environment: env, url: "https://x.test/up", http_method: "GET",
                          interval_seconds: 60, expected_status: 200, timeout_seconds: 5)
    end

    it "invalido se il progetto è solo-mobile (nessuna piattaforma uptime-capable)" do
      project = create(:project)
      project.platforms << create(:platform, organization: project.organization) # nativa
      env = create(:environment, organization: project.organization).tap { |e| project.environments << e }
      monitor = monitor_for(project, env)
      expect(monitor).not_to be_valid
      expect(monitor.errors[:project]).to include("needs a web/server platform to be monitored for uptime")
    end

    it "valido se il progetto ha una piattaforma uptime-capable (web/server)" do
      project = create(:project)
      project.platforms << create(:platform, :uptime_capable, organization: project.organization)
      env = create(:environment, organization: project.organization).tap { |e| project.environments << e }
      expect(monitor_for(project, env)).to be_valid
    end

    # Il vincolo è di AMMISSIONE, non un invariante permanente — stessa scelta di
    # uptime_capability_enabled qui sotto. Togliere una piattaforma da un progetto non deve
    # paralizzare un monitor già in funzione: Uptime::RecordCheck salva il monitor a OGNI ping
    # (last_checked_at, current_status), quindi una validazione viva sull'update fa esplodere la
    # transazione e il check non viene mai registrato. Visto in produzione: 1.440 fallimenti al
    # giorno — uno al minuto, esattamente la cadenza del dispatcher — dal 29 giugno al 7 luglio 2026,
    # con l'uptime page ferma e nessun errore visibile all'utente.
    it "un monitor GIÀ ESISTENTE resta salvabile se il progetto perde la piattaforma" do
      project = create(:project)
      platform = create(:platform, :uptime_capable, organization: project.organization)
      project.platforms << platform
      env = create(:environment, organization: project.organization).tap { |e| project.environments << e }
      monitor = monitor_for(project, env)
      monitor.save!

      project.platforms.destroy(platform)

      expect(monitor.reload.update(last_checked_at: Time.current, current_status: :up)).to be(true)
    end
  end

  describe "capability uptime per-ambiente (enforcement, on: :create)" do
    def uptime_capable_project
      create(:project).tap { |p| p.platforms << create(:platform, :uptime_capable, organization: p.organization) }
    end

    def monitor_for(project, env)
      Uptime::Monitor.new(project:, environment: env, url: "https://x.test/up", http_method: "GET",
                          interval_seconds: 60, expected_status: 200, timeout_seconds: 5)
    end

    it "valido quando l'uptime è abilitato di default sull'ambiente (override nil)" do
      project = uptime_capable_project
      env = create(:environment, organization: project.organization)
      project.environments << env
      expect(monitor_for(project, env)).to be_valid
    end

    it "invalido quando l'uptime è disabilitato di default sull'ambiente (ereditato)" do
      project = uptime_capable_project
      env = create(:environment, :uptime_off, organization: project.organization)
      project.environments << env
      monitor = monitor_for(project, env)
      expect(monitor).not_to be_valid
      expect(monitor.errors).to be_added(:base, :uptime_disabled)
    end

    it "invalido quando un override del progetto forza l'uptime OFF (default ON)" do
      project = uptime_capable_project
      env = create(:environment, organization: project.organization)
      create(:project_environment, project:, environment: env, uptime_enabled: false)
      monitor = monitor_for(project, env)
      expect(monitor).not_to be_valid
      expect(monitor.errors).to be_added(:base, :uptime_disabled)
    end

    it "valido quando un override del progetto forza l'uptime ON nonostante il default OFF" do
      project = uptime_capable_project
      env = create(:environment, :uptime_off, organization: project.organization)
      create(:project_environment, project:, environment: env, uptime_enabled: true)
      expect(monitor_for(project, env)).to be_valid
    end

    it "non invalida un monitor esistente quando l'uptime viene disabilitato dopo (on: :create)" do
      project = uptime_capable_project
      env = create(:environment, organization: project.organization)
      link = create(:project_environment, project:, environment: env)
      monitor = monitor_for(project, env)
      monitor.save!
      link.update!(uptime_enabled: false)
      expect(monitor.reload).to be_valid
    end
  end

  describe "gruppo (tenant-integrity org-level)" do
    it "valido senza gruppo (associazione opzionale)" do
      expect(create(:uptime_monitor, group: nil)).to be_valid
    end

    it "valido con un gruppo della stessa organizzazione del progetto" do
      monitor = build(:uptime_monitor)
      monitor.group = create(:uptime_group, organization: monitor.project.organization)
      expect(monitor).to be_valid
    end

    it "invalido con un gruppo di un'altra organizzazione" do
      monitor = build(:uptime_monitor)
      monitor.group = create(:uptime_group, organization: create(:organization))
      expect(monitor).not_to be_valid
      expect(monitor.errors[:group]).to be_present
    end
  end

  describe "enum current_status" do
    it "transita unknown → up → down" do
      m = create(:uptime_monitor)
      expect(m).to be_status_unknown
      m.status_up!
      expect(m.reload).to be_status_up
      m.status_down!
      expect(m.reload).to be_status_down
    end
  end

  describe "stato visualizzato quando il dato è vecchio (CYRA-209)" do
    # Il dispatcher gira ogni minuto: un monitor non è mai pingato più spesso della cadenza del
    # dispatcher (60s), per quanto piccolo sia interval_seconds. Stale oltre STALE_AFTER_INTERVALS (3)
    # intervalli effettivi → 3×60s = 180s con interval 60.
    it "#stale? è false entro la finestra, true oltre N intervalli" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        m = build(:uptime_monitor, interval_seconds: 60, last_checked_at: 170.seconds.ago)
        expect(m.stale?).to be(false)
        m.last_checked_at = 190.seconds.ago
        expect(m.stale?).to be(true)
      end
    end

    it "#stale? non scende sotto la cadenza del dispatcher (interval piccolo non accorcia la finestra)" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        m = build(:uptime_monitor, interval_seconds: 10, last_checked_at: 120.seconds.ago)
        expect(m.stale?).to be(false) # 120s < 180s (3×60s), non 3×10s
        m.last_checked_at = 200.seconds.ago
        expect(m.stale?).to be(true)
      end
    end

    it "#stale? scala con l'intervallo del monitor (intervallo lungo allunga la finestra)" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        m = build(:uptime_monitor, interval_seconds: 300, last_checked_at: 800.seconds.ago)
        expect(m.stale?).to be(false) # 800s < 900s (3×300s)
        m.last_checked_at = 1000.seconds.ago
        expect(m.stale?).to be(true)
      end
    end

    it "un monitor mai controllato non è stale (è già unknown)" do
      expect(build(:uptime_monitor, last_checked_at: nil)).not_to be_stale
    end

    it "un monitor in pausa non è stale (non ci si aspetta che venga pingato)" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        expect(build(:uptime_monitor, active: false, current_status: :up, last_checked_at: 1.hour.ago)).not_to be_stale
      end
    end

    it "#display_status: unknown se il dato è vecchio, altrimenti lo stato persistito" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        expect(build(:uptime_monitor, current_status: :up, last_checked_at: 30.seconds.ago).display_status).to eq(:up)
        expect(build(:uptime_monitor, current_status: :up, last_checked_at: 1.hour.ago).display_status).to eq(:unknown)
        expect(build(:uptime_monitor, current_status: :down, last_checked_at: 1.hour.ago).display_status).to eq(:unknown)
      end
    end

    describe "scope .stale / .fresh (conteggi stale-aware)" do
      it "separa i monitor con dato vecchio da quelli aggiornati (mai-controllato = fresh, è già unknown)" do
        travel_to(Time.utc(2026, 6, 26, 12)) do
          fresh = create(:uptime_monitor, interval_seconds: 60, current_status: :up, last_checked_at: 30.seconds.ago)
          stale = create(:uptime_monitor, interval_seconds: 60, current_status: :up, last_checked_at: 1.hour.ago)
          never = create(:uptime_monitor, interval_seconds: 60, last_checked_at: nil)
          paused = create(:uptime_monitor, interval_seconds: 60, active: false, current_status: :up, last_checked_at: 1.hour.ago)
          expect(described_class.stale).to contain_exactly(stale)
          expect(described_class.fresh).to contain_exactly(fresh, never, paused)
        end
      end
    end

    describe ".for_display_statuses (filtro sullo stato mostrato)" do
      it "'up' esclude gli up stale; 'unknown' li include (insieme ai persistiti unknown)" do
        travel_to(Time.utc(2026, 6, 26, 12)) do
          fresh_up = create(:uptime_monitor, current_status: :up, last_checked_at: 30.seconds.ago)
          stale_up = create(:uptime_monitor, current_status: :up, last_checked_at: 1.hour.ago)
          never = create(:uptime_monitor, current_status: :unknown, last_checked_at: nil)
          expect(described_class.for_display_statuses([ "up" ])).to contain_exactly(fresh_up)
          expect(described_class.for_display_statuses([ "unknown" ])).to contain_exactly(stale_up, never)
        end
      end

      it "'down' esclude i down stale (mostrati unknown)" do
        travel_to(Time.utc(2026, 6, 26, 12)) do
          fresh_down = create(:uptime_monitor, current_status: :down, last_checked_at: 30.seconds.ago)
          create(:uptime_monitor, current_status: :down, last_checked_at: 1.hour.ago) # stale → unknown
          expect(described_class.for_display_statuses([ "down" ])).to contain_exactly(fresh_down)
        end
      end

      it "filtro vuoto o con tutti gli stati → nessun filtro (tutti i monitor)" do
        m1 = create(:uptime_monitor, current_status: :up)
        m2 = create(:uptime_monitor, current_status: :down)
        expect(described_class.for_display_statuses([])).to contain_exactly(m1, m2)
        expect(described_class.for_display_statuses(%w[unknown up down])).to contain_exactly(m1, m2)
      end
    end

    # CYRA-492 — con sessanta monitor il caduto non si trova a occhio: l'ordinamento di default lo porta
    # in cima. Stale-aware come display_status: un verde ingannevole (dato vecchio) non resta sopra un
    # guasto reale, e un monitor in pausa non è un guasto in corso.
    describe ".health_order (i non sani per primi)" do
      it "mette in cima i giù, poi il dato incerto, infine i sani (a dispetto dell'ordine alfabetico)" do
        travel_to(Time.utc(2026, 6, 26, 12)) do
          up      = create(:uptime_monitor, current_status: :up, last_checked_at: 30.seconds.ago, name: "A up")
          down    = create(:uptime_monitor, current_status: :down, last_checked_at: 30.seconds.ago, name: "Z down")
          unknown = create(:uptime_monitor, current_status: :unknown, last_checked_at: nil, name: "M unknown")
          expect(described_class.health_order.to_a).to eq([ down, unknown, up ])
        end
      end

      it "un giù col dato vecchio scende tra gli incerti, non resta in cima (mostrato unknown)" do
        travel_to(Time.utc(2026, 6, 26, 12)) do
          fresh_down = create(:uptime_monitor, current_status: :down, last_checked_at: 30.seconds.ago)
          stale_down = create(:uptime_monitor, current_status: :down, last_checked_at: 1.hour.ago)
          up         = create(:uptime_monitor, current_status: :up, last_checked_at: 30.seconds.ago)
          ordered = described_class.health_order.to_a
          expect(ordered.first).to eq(fresh_down)
          expect(ordered[1]).to eq(stale_down)
          expect(ordered.last).to eq(up)
        end
      end

      it "un monitor in pausa conta come sano: non finisce in cima anche se era giù" do
        travel_to(Time.utc(2026, 6, 26, 12)) do
          paused_down = create(:uptime_monitor, active: false, current_status: :down, last_checked_at: 30.seconds.ago)
          fresh_down  = create(:uptime_monitor, active: true, current_status: :down, last_checked_at: 30.seconds.ago)
          ordered = described_class.health_order.to_a
          expect(ordered.first).to eq(fresh_down)
          expect(ordered.last).to eq(paused_down)
        end
      end

      it "a parità di stato rispetta l'ordinamento appeso da chi chiama (nome)" do
        travel_to(Time.utc(2026, 6, 26, 12)) do
          bravo = create(:uptime_monitor, current_status: :down, last_checked_at: 30.seconds.ago, name: "Bravo")
          alfa  = create(:uptime_monitor, current_status: :down, last_checked_at: 30.seconds.ago, name: "Alfa")
          ordered = described_class.health_order.order(Arel.sql("LOWER(uptime_monitors.name)")).to_a
          expect(ordered).to eq([ alfa, bravo ])
        end
      end
    end
  end

  describe "scopes" do
    it ".active esclude i monitor in pausa" do
      a = create(:uptime_monitor, active: true)
      create(:uptime_monitor, active: false)
      expect(described_class.active).to contain_exactly(a)
    end

    describe ".due (scaduti da pingare)" do
      it "include mai-controllati, esclude controllati entro l'intervallo, include oltre" do
        travel_to(Time.utc(2026, 6, 26, 12)) do
          never    = create(:uptime_monitor, interval_seconds: 60, last_checked_at: nil)
          recent   = create(:uptime_monitor, interval_seconds: 60, last_checked_at: 10.seconds.ago)
          overdue  = create(:uptime_monitor, interval_seconds: 60, last_checked_at: 61.seconds.ago)
          paused   = create(:uptime_monitor, interval_seconds: 60, last_checked_at: nil, active: false)
          due = described_class.due
          expect(due).to include(never, overdue)
          expect(due).not_to include(recent, paused)
        end
      end

      # Anti-drift: il dispatcher gira ogni minuto e `last_checked_at` è scritto qualche secondo DOPO
      # il tick. Con intervallo == cadenza (60s) la maturità cade poco oltre il tick successivo: senza
      # tolleranza il monitor verrebbe saltato per un giro → intervallo effettivo 120s. Un monitor che
      # matura entro la tolleranza (DISPATCH_GRACE) dev'essere già "due" al tick corrente.
      it "include un monitor che matura entro la tolleranza del dispatcher (no drift a 2× intervallo)" do
        travel_to(Time.utc(2026, 6, 26, 12)) do
          maturing = create(:uptime_monitor, interval_seconds: 60, last_checked_at: 40.seconds.ago)
          expect(described_class.due).to include(maturing)
        end
      end
    end
  end

  describe ".uptime_percents" do
    it "ids vuoti → hash vuoto" do
      expect(described_class.uptime_percents([], 1.hour.ago)).to eq({})
    end

    it "calcola la % up/totale nella finestra; nil senza check" do
      m = create(:uptime_monitor)
      create(:uptime_check, monitor: m, up: true, checked_at: 5.minutes.ago)
      create(:uptime_check, monitor: m, up: true, checked_at: 4.minutes.ago)
      create(:uptime_check, monitor: m, up: false, checked_at: 3.minutes.ago)
      create(:uptime_check, monitor: m, up: true, checked_at: 2.hours.ago) # fuori finestra
      no_checks = create(:uptime_monitor)

      result = described_class.uptime_percents([ m.id, no_checks.id ], 1.hour.ago)
      expect(result[m.id]).to eq(66.67)   # 2 up / 3 totali nella finestra
      expect(result).not_to have_key(no_checks.id)
    end
  end

  describe ".buckets_for" do
    it "ids vuoti → hash vuoto" do
      expect(described_class.buckets_for([], "24h")).to eq({})
    end

    it "24h → 48 blocchi; aggrega up/partial/down e riempie i vuoti (grigi)" do
      m = create(:uptime_monitor)
      now = Time.utc(2026, 6, 27, 12, 0, 0)
      create(:uptime_check, monitor: m, up: true,  response_time_ms: 40, checked_at: now - 5.minutes)   # ultimo blocco → up
      create(:uptime_check, monitor: m, up: true,  response_time_ms: 50, checked_at: now - 35.minutes)  # blocco -2: misto
      create(:uptime_check, monitor: m, up: false, response_time_ms: nil, checked_at: now - 36.minutes) #   → partial
      create(:uptime_check, monitor: m, up: false, response_time_ms: nil, checked_at: now - 65.minutes)  # blocco -3 → down

      buckets = described_class.buckets_for([ m.id ], "24h", now)[m.id]
      expect(buckets.size).to eq(48)
      expect(buckets.last).to include(status: :up, avg_ms: 40)
      expect(buckets[-2][:status]).to eq(:partial)
      expect(buckets[-3][:status]).to eq(:down)
      expect(buckets.first[:status]).to eq(:empty)
    end

    it "un now con i nanosecondi non sposta i blocchi di uno: l'ultimo resta quello corrente" do
      m = create(:uptime_monitor)
      now = Time.utc(2026, 6, 27, 12, 0, Rational(1_234_567_891, 1_000_000_000))
      create(:uptime_check, monitor: m, up: true, response_time_ms: 40, checked_at: now - 5.minutes)

      buckets = described_class.buckets_for([ m.id ], "24h", now)[m.id]
      expect(buckets.last).to include(status: :up, avg_ms: 40)
      expect(buckets[-2][:status]).to eq(:empty)
    end

    it "monitor senza check → tutti i blocchi empty (grigi)" do
      m = create(:uptime_monitor)
      buckets = described_class.buckets_for([ m.id ], "30m")[m.id]
      expect(buckets.size).to eq(30)
      expect(buckets.map { |b| b[:status] }.uniq).to eq([ :empty ])
    end
  end

  describe "status page pubblica (public_status_enabled)" do
    it "di default un monitor NON è pubblico (opt-in: spento finché non lo si attiva)" do
      expect(create(:uptime_monitor).public_status_enabled?).to be(false)
      expect(create(:uptime_monitor).public?).to be(false)
    end

    it "#public? riflette il flag" do
      expect(build(:uptime_monitor, public_status_enabled: true).public?).to be(true)
    end

    it ".public_status include solo i monitor pubblicati" do
      shown  = create(:uptime_monitor, public_status_enabled: true)
      create(:uptime_monitor, public_status_enabled: false)
      expect(described_class.public_status).to contain_exactly(shown)
    end
  end

  describe "#open_incident / #paused?" do
    it "open_incident: nil senza incident aperti, l'aperto quando presente" do
      m = create(:uptime_monitor)
      expect(m.open_incident).to be_nil
      inc = create(:uptime_incident, monitor: m, resolved_at: nil)
      create(:uptime_incident, :resolved, monitor: m)
      expect(m.open_incident).to eq(inc)
    end

    it "paused? è true quando non attivo" do
      expect(build(:uptime_monitor, active: false).paused?).to be(true)
      expect(build(:uptime_monitor, active: true).paused?).to be(false)
    end
  end

  describe "associazioni (0/N + cascade)" do
    it "0 check/incident: monitor valido" do
      m = create(:uptime_monitor)
      expect(m.checks).to be_empty
      expect(m.incidents).to be_empty
    end

    it "cascade alla distruzione del monitor" do
      m = create(:uptime_monitor)
      create_list(:uptime_check, 2, monitor: m)
      create(:uptime_incident, monitor: m)
      expect { m.destroy }.to change(Uptime::Check, :count).by(-2).and change(Uptime::Incident, :count).by(-1)
    end
  end

  describe "validazioni check ssl/keyword" do
    it "ssl_expiry_warn_days nil è valido (check disattivo)" do
      expect(build(:uptime_monitor, ssl_expiry_warn_days: nil)).to be_valid
    end

    it "ssl_expiry_warn_days 0 è invalido (confine: minimo 1)" do
      monitor = build(:uptime_monitor, ssl_expiry_warn_days: 0)
      expect(monitor).not_to be_valid
      expect(monitor.errors[:ssl_expiry_warn_days]).to be_present
    end

    it "ssl_expiry_warn_days 1 è valido" do
      expect(build(:uptime_monitor, ssl_expiry_warn_days: 1)).to be_valid
    end

    it "keyword con HEAD è invalida (HEAD non ha body)" do
      monitor = build(:uptime_monitor, http_method: "HEAD", expected_body_keyword: "ok")
      expect(monitor).not_to be_valid
      expect(monitor.errors[:expected_body_keyword]).to be_present
    end

    it "keyword con GET è valida" do
      expect(build(:uptime_monitor, http_method: "GET", expected_body_keyword: "ok")).to be_valid
    end
  end

  # CYRA-151: il monitor non è più solo HTTP. check_type apre tcp (porta), dns e ping; url resta il
  # bersaglio http, host/port quello dei check non-web.
  describe "tipo di check (check_type)" do
    it "di default è http (i monitor esistenti restano http)" do
      expect(build(:uptime_monitor).check_type).to eq("http")
      expect(build(:uptime_monitor)).to be_check_type_http
    end

    it "espone i quattro tipi http/tcp/dns/ping" do
      expect(described_class.check_types.keys).to contain_exactly("http", "tcp", "dns", "ping")
    end

    describe "http" do
      it "richiede una url http(s), host/port irrilevanti" do
        expect(build(:uptime_monitor, url: nil)).not_to be_valid
        expect(build(:uptime_monitor, url: "ftp://x")).not_to be_valid
        expect(build(:uptime_monitor, host: nil, port: nil)).to be_valid
      end
    end

    describe "tcp (porta)" do
      it "richiede host e porta, non la url" do
        expect(build(:uptime_monitor, :tcp)).to be_valid
        expect(build(:uptime_monitor, :tcp, url: nil)).to be_valid
      end

      it "invalido senza host" do
        expect(build(:uptime_monitor, :tcp, host: nil)).not_to be_valid
      end

      it "invalido senza porta o con porta fuori range 1..65535" do
        expect(build(:uptime_monitor, :tcp, port: nil)).not_to be_valid
        expect(build(:uptime_monitor, :tcp, port: 0)).not_to be_valid
        expect(build(:uptime_monitor, :tcp, port: 70_000)).not_to be_valid
        expect(build(:uptime_monitor, :tcp, port: 5432)).to be_valid
      end
    end

    describe "dns" do
      it "richiede host, non la url né la porta" do
        expect(build(:uptime_monitor, :dns)).to be_valid
        expect(build(:uptime_monitor, :dns, host: nil)).not_to be_valid
      end
    end

    describe "ping" do
      it "richiede host, non la url né la porta" do
        expect(build(:uptime_monitor, :ping)).to be_valid
        expect(build(:uptime_monitor, :ping, host: nil)).not_to be_valid
      end
    end

    it "normalizza host (strip + downcase)" do
      m = create(:uptime_monitor, :tcp, host: "  DB.Example.COM  ")
      expect(m.host).to eq("db.example.com")
    end
  end

  describe "#target (bersaglio leggibile per tipo)" do
    it "http → url" do
      expect(build(:uptime_monitor, url: "https://x.test/up").target).to eq("https://x.test/up")
    end

    it "tcp → host:porta" do
      expect(build(:uptime_monitor, :tcp, host: "db.test", port: 5432).target).to eq("db.test:5432")
    end

    it "dns e ping → host" do
      expect(build(:uptime_monitor, :dns, host: "x.test").target).to eq("x.test")
      expect(build(:uptime_monitor, :ping, host: "x.test").target).to eq("x.test")
    end
  end

  # CYRA-151: soglia di latenza per-monitor (nil = disattiva), stesso pattern di ssl_expiry_warn_days.
  describe "validazione latency_threshold_ms" do
    it "nil è valido (avviso di lentezza disattivo)" do
      expect(build(:uptime_monitor, latency_threshold_ms: nil)).to be_valid
    end

    it "0 o negativo è invalido (deve essere > 0)" do
      expect(build(:uptime_monitor, latency_threshold_ms: 0)).not_to be_valid
      expect(build(:uptime_monitor, latency_threshold_ms: -1)).not_to be_valid
    end

    it "un valore positivo è valido" do
      expect(build(:uptime_monitor, latency_threshold_ms: 800)).to be_valid
    end
  end

  describe "#top_incidents" do
    it "solo incident di primo livello, recenti prima" do
      m = create(:uptime_monitor)
      old = create(:uptime_incident, monitor: m, started_at: 2.hours.ago)
      recent = create(:uptime_incident, monitor: m, started_at: 10.minutes.ago)
      create(:uptime_incident, monitor: m, parent: recent, started_at: 1.hour.ago) # figlio: escluso
      expect(m.top_incidents.to_a).to eq([ recent, old ])
    end
  end

  describe "#current_announcement" do
    it "restituisce il banner solo se live" do
      m = create(:uptime_monitor)
      expect(m.current_announcement).to be_nil
      ann = create(:uptime_announcement, monitor: m)
      expect(m.reload.current_announcement).to eq(ann)
    end

    it "nil se il banner è spento o fuori finestra" do
      m = create(:uptime_monitor)
      create(:uptime_announcement, :expired, monitor: m)
      expect(m.reload.current_announcement).to be_nil
    end
  end

  describe "rollup nella stessa tabella (granularity)" do
    it "monitor.checks vede solo i ping raw, non gli aggregati (regressione: RecordCheck/lista recenti)" do
      m = create(:uptime_monitor)
      ping = create(:uptime_check, monitor: m)
      create(:uptime_check, :hourly, monitor: m, checked_at: 1.hour.ago.beginning_of_hour)
      create(:uptime_check, :daily, monitor: m, checked_at: 1.day.ago.beginning_of_day)

      expect(m.checks).to contain_exactly(ping)
      expect(m.checks.recent.to_a).to eq([ ping ])
    end

    describe ".buckets_for per sorgente" do
      it "7d (56 blocchi) legge dagli hourly, non dai ping raw" do
        m = create(:uptime_monitor)
        now = Time.utc(2026, 6, 27, 12)
        create(:uptime_check, monitor: m, up: true, checked_at: now - 10.minutes) # raw: escluso dal 7d
        create(:uptime_check, :hourly, monitor: m, checks_total: 60, checks_up: 30, avg_response_ms: 100,
               checked_at: (now - 2.hours).beginning_of_hour)

        buckets = described_class.buckets_for([ m.id ], "7d", now)[m.id]
        expect(buckets.size).to eq(56)
        filled = buckets.reject { |b| b[:status] == :empty }
        expect(filled.size).to eq(1)
        expect(filled.first).to include(status: :partial, total: 60, up: 30, avg_ms: 100)
      end

      it "30d = 30 blocchi (sorgente hourly)" do
        m = create(:uptime_monitor)
        expect(described_class.buckets_for([ m.id ], "30d").size).to eq(1)
        expect(described_class.buckets_for([ m.id ], "30d")[m.id].size).to eq(30)
      end

      it "1y = 365 blocchi dai daily; l'ultimo (oggi) sovrapposto dagli hourly" do
        m = create(:uptime_monitor)
        now = Time.utc(2026, 6, 27, 12)
        create(:uptime_check, :daily, monitor: m, checks_total: 1_440, checks_up: 1_440, avg_response_ms: 90,
               checked_at: (now - 10.days).beginning_of_day)
        create(:uptime_check, :hourly, monitor: m, checks_total: 60, checks_up: 45, avg_response_ms: 200,
               checked_at: now.beginning_of_hour - 1.hour) # oggi → overlay dell'ultimo blocco

        buckets = described_class.buckets_for([ m.id ], "1y", now)[m.id]
        expect(buckets.size).to eq(365)
        expect(buckets.last).to include(status: :partial, total: 60, up: 45, avg_ms: 200)
        up_blocks = buckets.select { |b| b[:status] == :up }
        expect(up_blocks.size).to eq(1)
        expect(up_blocks.first).to include(total: 1_440, up: 1_440, avg_ms: 90)
      end
    end

    describe ".uptime_percents / .uptime_percents_for_windows per sorgente" do
      it "uptime_percents legge dalla sorgente indicata (hourly), ignorando il raw" do
        m = create(:uptime_monitor)
        create(:uptime_check, :hourly, monitor: m, checks_total: 100, checks_up: 90,
               checked_at: 2.hours.ago.beginning_of_hour)
        create(:uptime_check, monitor: m, up: false, checked_at: 1.minute.ago) # raw: ignorato con source hourly

        expect(described_class.uptime_percents([ m.id ], 7.days.ago, source: :hourly)[m.id]).to eq(90.0)
      end

      it "ogni finestra SLA usa la sua sorgente (raw breve, hourly media, daily annuale)" do
        m = create(:uptime_monitor)
        now = Time.current
        create(:uptime_check, monitor: m, up: true, checked_at: 1.hour.ago)
        create(:uptime_check, monitor: m, up: false, checked_at: 2.hours.ago)
        create(:uptime_check, :hourly, monitor: m, checks_total: 10, checks_up: 8, checked_at: 3.days.ago.beginning_of_hour)
        create(:uptime_check, :daily, monitor: m, checks_total: 100, checks_up: 100, checked_at: 100.days.ago.beginning_of_day)

        windows = Uptime::Monitor::RANGES.keys.index_with { |k| now - Uptime::Monitor.range_duration(k) }
        res = described_class.uptime_percents_for_windows([ m.id ], windows)[m.id]
        expect(res["24h"]).to eq(50.0)  # 1 up / 2 ping raw
        expect(res["7d"]).to eq(80.0)   # 8 / 10 hourly
        expect(res["1y"]).to eq(100.0)  # 100 / 100 daily
        expect(res["30m"]).to be_nil    # finestra raw senza dati → nil
      end
    end
  end
end
