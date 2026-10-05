# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Content do
  let(:project) { create(:project) }

  it "costruisce title/body/url/project per un errore" do
    group = create(:error_group, project: project, title: "RuntimeError: boom", culprit: "App#call")
    content = described_class.for(event_type: "error_new", subject: group)
    expect(content.title).to include("RuntimeError: boom")
    expect(content.body).to eq("App#call")
    expect(content.url).to include(group.id)
    expect(content.project).to eq(project)
  end

  it "costruisce title/body/url/project per uno spike di errore" do
    group = create(:error_group, project: project, title: "RuntimeError: boom", culprit: "App#call")
    content = described_class.for(event_type: "error_spike", subject: group)
    expect(content.title).to include("RuntimeError: boom")
    expect(content.body).to eq("App#call")
    expect(content.url).to include(group.id)
    expect(content.project).to eq(project)
  end

  it "costruisce title/body/url per un incident uptime" do
    monitor = create(:uptime_monitor, project: project)
    incident = create(:uptime_incident, monitor: monitor)
    content = described_class.for(event_type: "uptime_down", subject: incident)
    expect(content.title).to include(project.name)
    expect(content.body).to include(monitor.url)
    expect(content.project).to eq(project)
  end

  # CYRA-151: un monitor non-web non ha url — down/up devono nominare il bersaglio (host:porta),
  # altrimenti l'avviso arriva senza dire cosa è caduto ("  non risponde — incident aperto.").
  it "uptime_down su un monitor non-web nomina il target host:porta" do
    monitor = create(:uptime_monitor, :tcp, project: project, host: "db.test", port: 5432)
    incident = create(:uptime_incident, monitor: monitor)
    content = described_class.for(event_type: "uptime_down", subject: incident)
    expect(content.body).to include("db.test:5432")
  end

  it "uptime_up su un monitor non-web nomina il target host:porta" do
    monitor = create(:uptime_monitor, :tcp, project: project, host: "db.test", port: 5432)
    incident = create(:uptime_incident, :resolved, monitor: monitor)
    content = described_class.for(event_type: "uptime_up", subject: incident)
    expect(content.body).to include("db.test:5432")
  end

  # CYRA-151: risposta lenta. subject = il monitor (come uptime_ssl_expiring); il body usa `target`
  # (funziona anche per i monitor non-web) e la soglia configurata.
  it "costruisce title/body/url per una risposta lenta (uptime_slow)" do
    monitor = create(:uptime_monitor, project: project, latency_threshold_ms: 500)
    content = described_class.for(event_type: "uptime_slow", subject: monitor)
    expect(content.title).to include(project.name)
    expect(content.body).to include(monitor.target).and include("500")
    expect(content.url).to include(monitor.id)
    expect(content.project).to eq(project)
  end

  it "uptime_slow su un monitor non-web usa il target host:porta (nessuna url)" do
    monitor = create(:uptime_monitor, :tcp, project: project, host: "db.test", port: 5432, latency_threshold_ms: 300)
    content = described_class.for(event_type: "uptime_slow", subject: monitor)
    expect(content.body).to include("db.test:5432")
  end

  # CYRA-477 Scenario 3: l'avviso di cron mancato deve dire DA QUANTO il job è fermo, non solo la
  # cadenza attesa — un allarme che finalmente suona deve dire da quanto il guasto è in corso.
  describe "cron_missed" do
    it "il body dice da quanto il job è fermo (dall'ultimo check-in) oltre alla cadenza" do
      monitor = create(:cron_monitor, project:, name: "Nightly digest",
                       last_check_in_at: 4.days.ago, expected_interval_minutes: 2)
      content = described_class.for(event_type: "cron_missed", subject: monitor)
      expect(content.title).to include("Nightly digest").and include(project.name)
      expect(content.body).to include("4").and include("2")
      expect(content.url).to include("cron")
      expect(content.project).to eq(project)
    end

    it "senza alcun check-in il body lo dichiara (mai arrivato), senza crashare" do
      monitor = create(:cron_monitor, project:, last_check_in_at: nil, expected_interval_minutes: 2)
      content = described_class.for(event_type: "cron_missed", subject: monitor)
      expect(content.body).to be_present.and include("2")
    end
  end

  it "costruisce title/body/url per un performance_issue (metric_threshold)" do
    group = create(:metric_group, :performance_issue, project: project, title: "N+1 SELECT users")
    content = described_class.for(event_type: "metric_threshold", subject: group)
    expect(content.title).to include(project.name)
    expect(content.body).to eq("N+1 SELECT users")
    expect(content.url).to include(group.id)
    expect(content.project).to eq(project)
  end

  # CYRA-44: la regressione deve mostrare la release che l'ha causata (regressed_in_release), NON la
  # release più recente osservata (subject.release) — che può essere un residuo pre-fix fuorviante.
  describe "error_regression" do
    it "mostra regressed_in_release nel body" do
      group = create(:error_group, project:, culprit: "App#call",
                     release: "v1.0", regressed_in_release: "v2.0")
      content = described_class.for(event_type: "error_regression", subject: group)
      expect(content.body).to include("v2.0")
      expect(content.body).not_to include("v1.0")   # la release residua non deve comparire
    end

    it "senza regressed_in_release non mostra release (solo culprit)" do
      group = create(:error_group, project:, culprit: "App#call", regressed_in_release: nil)
      content = described_class.for(event_type: "error_regression", subject: group)
      expect(content.body).to eq("App#call")
    end
  end

  # CYRA-55: alert sui log error/fatal. Il subject è una singola Logs::Entry (stream append-only):
  # title = livello + progetto, body = il messaggio del log, url = la show della entry.
  it "costruisce title/body/url/project per un log error/fatal (log_alert)" do
    entry = create(:log_entry, project: project, level: :fatal, message: "payment gateway unreachable")
    content = described_class.for(event_type: "log_alert", subject: entry)
    expect(content.title).to include(project.name)
    expect(content.body).to eq("payment gateway unreachable")
    expect(content.url).to include(entry.id)
    expect(content.project).to eq(project)
  end

  # CYRA-212: allarme agenti "lavorazioni bloccate". Org-scoped: subject = l'organizzazione, project nil,
  # url alla lista degli host di automazione.
  it "costruisce title/body/url per l'allarme agenti (agents_stalled, org-scoped)" do
    organization = create(:organization, name: "Acme")
    content = described_class.for(event_type: "agents_stalled", subject: organization)
    expect(content.title).to include("Acme")
    expect(content.body).to be_present
    expect(content.url).to eq("/member/agents")
    expect(content.project).to be_nil
  end

  # CYRA-282: allarme "una macchina butta via il lavoro". Org-scoped ma subject = l'host, url alla SUA
  # scheda dove il rendimento mostra la quota di fallimenti.
  it "costruisce title/body/url per l'allarme host in errore (agents_host_failing)" do
    host = create(:agent_host, hostname: "minion-1.local")
    content = described_class.for(event_type: "agents_host_failing", subject: host)
    expect(content.title).to include("minion-1.local")
    expect(content.body).to be_present
    expect(content.url).to eq("/member/agents/#{host.id}")
    expect(content.project).to be_nil
  end

  # CYRA-450: allarme "una macchina è ferma". Org-scoped, subject = l'host, url alla SUA scheda.
  it "costruisce title/body/url per l'allarme host fermo (agents_host_stale)" do
    host = create(:agent_host, hostname: "minion-2.local")
    content = described_class.for(event_type: "agents_host_stale", subject: host)
    expect(content.title).to include("minion-2.local")
    expect(content.body).to be_present
    expect(content.url).to eq("/member/agents/#{host.id}")
    expect(content.project).to be_nil
  end

  # CYRA-520 — il testo diceva «Macchina ferma — controlla che sia accesa e connessa», ma il nome è
  # quello del server, che nel caso reale era acceso e verde per tutti e 49 gli avvisi: chi leggeva
  # andava a controllare la cosa sbagliata. Ferma è l'automazione che gira sulla macchina.
  it "l'allarme host fermo parla dell'automazione, non della macchina" do
    host = create(:agent_host, hostname: "minion-2.local")

    content = I18n.with_locale(:it) { described_class.for(event_type: "agents_host_stale", subject: host) }

    expect(content.title).to match(/automazione/i)
    expect(content.body).to match(/automazione/i)
    expect(content.body).not_to match(/controlla che sia accesa/i)
    # Il collegamento porta all'automazione, non al server con lo stesso nome.
    expect(content.url).to eq("/member/agents/#{host.id}")
  end

  # CYRA-147: statistiche del sito. subject = il progetto stesso (nessun modello incident), url alla
  # dashboard analytics filtrata sul progetto.
  %w[analytics_traffic_drop analytics_traffic_spike].each do |event_type|
    it "costruisce title/body/url/project per #{event_type} (subject = progetto)" do
      content = described_class.for(event_type: event_type, subject: project)
      expect(content.title).to include(project.name)
      expect(content.body).to be_present
      expect(content.url).to include(project.id)
      expect(content.project).to eq(project)
    end
  end

  # CYRA-147: idee. subject = Ideas::Idea (created) / Ideas::Comment (commented); il body porta il
  # titolo dell'idea, l'url la pagina dell'idea.
  it "costruisce title/body/url/project per idea_created (subject = idea)" do
    idea = create(:idea, organization: project.organization, project: project, title: "Dark mode ovunque")
    content = described_class.for(event_type: "idea_created", subject: idea)
    expect(content.title).to include(project.name)
    expect(content.body).to eq("Dark mode ovunque")
    expect(content.url).to include(idea.id)
    expect(content.project).to eq(project)
  end

  it "costruisce title/body/url/project per idea_commented (subject = commento, punta all'idea)" do
    idea = create(:idea, organization: project.organization, project: project, title: "Dark mode ovunque")
    comment = create(:idea_comment, idea: idea, organization: project.organization)
    content = described_class.for(event_type: "idea_commented", subject: comment)
    expect(content.title).to include(project.name)
    expect(content.body).to eq("Dark mode ovunque")
    expect(content.url).to include(idea.id)
    expect(content.project).to eq(project)
  end

  # CYRA-147: attività in scadenza. subject = Workload::Action, team-scoped → project nil.
  it "costruisce title/body/url per workload_due_soon (subject = action, project nil)" do
    action = create(:workload_action, title: "Preparare fiera")
    content = described_class.for(event_type: "workload_due_soon", subject: action)
    expect(content.title).to include("Preparare fiera")
    expect(content.body).to be_present
    expect(content.url).to include(action.id)
    expect(content.project).to be_nil
  end

  # CYRA-147: addestramento dataset finito/fallito. subject = Datasets::Training, project via il dataset.
  it "costruisce title/body/url/project per dataset_training_completed (subject = training)" do
    training = create(:dataset_training, :done)
    content = described_class.for(event_type: "dataset_training_completed", subject: training)
    expect(content.title).to include(training.dataset.name)
    expect(content.body).to be_present
    expect(content.url).to include(training.id)
    expect(content.project).to eq(training.dataset.project)
  end

  it "per dataset_training_failed il body è il messaggio d'errore snapshottato" do
    training = create(:dataset_training, :failed, error_message: "gateway LLM irraggiungibile")
    content = described_class.for(event_type: "dataset_training_failed", subject: training)
    expect(content.title).to include(training.dataset.name)
    expect(content.body).to eq("gateway LLM irraggiungibile")
    expect(content.url).to include(training.id)
    expect(content.project).to eq(training.dataset.project)
  end

  it "solleva ArgumentError per un event_type non supportato" do
    expect { described_class.for(event_type: "bogus_event", subject: create(:error_group)) }
      .to raise_error(ArgumentError)
  end

  # Cinque tipi di avviso non avevano alcun test: se il testo si rompesse — un titolo senza il nome
  # del controllo, un corpo senza i giorni che restano — l'avviso partirebbe monco e nessuno se ne
  # accorgerebbe finché non arriva a una persona.
  # I giorni si contano con `floor`: una scadenza a "dieci giorni esatti" diventa nove appena passa
  # un microsecondo fra il create e la lettura. Il margine di sei ore rende il conto stabile.
  it "uptime_ssl_expiring dice quanti giorni restano al certificato" do
    monitor = create(:uptime_monitor, project: project, ssl_expires_at: 10.days.from_now + 6.hours)
    content = described_class.for(event_type: "uptime_ssl_expiring", subject: monitor)

    expect(content.title).to include(project.name)
    expect(content.body).to include("10")
    expect(content.project).to eq(project)
  end

  it "uptime_ssl_expiring senza data di scadenza non esplode" do
    monitor = create(:uptime_monitor, project: project, ssl_expires_at: nil)

    expect { described_class.for(event_type: "uptime_ssl_expiring", subject: monitor) }.not_to raise_error
  end

  # CYRA-679 — stima e mountpoint riletti dallo stato sull'host.
  it "server_disk_forecast dice i giorni e il mountpoint" do
    host = create(:server_host, name: "sentinel",
                  disk_forecast_state: { "days" => 9.5, "current_pct" => 81.0 },
                  resource_pressure: { "data_volume_disk" => { "mountpoint" => "/mnt/data", "pct" => 81.0 } })
    content = described_class.for(event_type: "server_disk_forecast", subject: host)

    expect(content.title).to include("sentinel")
    expect(content.body).to include("/mnt/data")
    expect(content.body).to include("10")
    expect(content.project).to be_nil
  end

  # CYRA-678 — il body nomina le unit cadute, e le escluse per-host non compaiono.
  it "server_service_failed nomina le unit e salta le escluse" do
    host = create(:server_host, name: "sentinel",
                  failed_services: %w[backup.service motd-news.service],
                  ignored_service_patterns: [ "motd-news" ])
    content = described_class.for(event_type: "server_service_failed", subject: host)

    expect(content.body).to include("backup.service")
    expect(content.body).not_to include("motd-news")
    expect(content.details).to eq(%w[backup.service])
  end

  it "server_security_updates porta il conteggio riletto dallo snapshot host" do
    host = create(:server_host, name: "sentinel", security_updates_available: 4)
    content = described_class.for(event_type: "server_security_updates", subject: host)

    expect(content.title).to include("sentinel")
    expect(content.body).to include("4")
    expect(content.project).to be_nil
  end

  it "server_silent dice da quanto i dati sono fermi" do
    host = create(:server_host, name: "sentinel", hostname: "sentinel.interno",
                  last_seen_at: 20.minutes.ago)
    content = described_class.for(event_type: "server_silent", subject: host)

    expect(content.title).to include("sentinel")
    expect(content.body).to include("sentinel.interno")
    expect(content.body).to include("20")
    expect(content.project).to be_nil
  end

  it "server_container_up nomina l'host tornato a posto, senza elenco" do
    host = create(:server_host, name: "sentinel", hostname: "sentinel.interno")
    content = described_class.for(event_type: "server_container_up", subject: host)

    expect(content.title).to include("sentinel")
    expect(content.body).to include("sentinel.interno")
    expect(content.details).to be_nil
    expect(content.project).to be_nil
  end

  it "server_container_up ripiega sul nome quando l'hostname manca" do
    host = create(:server_host, name: "sentinel", hostname: nil)
    content = described_class.for(event_type: "server_container_up", subject: host)

    expect(content.body).to include("sentinel")
  end

  it "server_db_connection_usage senza max utilizzabile scrive — al posto della percentuale" do
    host = create(:server_host, name: "sentinel",
                  database_snapshot: { "connections" => { "total" => 7 } })
    content = described_class.for(event_type: "server_db_connection_usage", subject: host)

    expect(content.body).to include("—")
  end

  it "server_data_volume_disk e server_inode reggono uno stato di pressione assente" do
    host = create(:server_host, name: "sentinel", resource_pressure: {})
    %w[server_data_volume_disk server_inode].each do |event_type|
      content = described_class.for(event_type:, subject: host)

      expect(content.title).to include("sentinel")
      expect(content.body).to include("—")
    end
  end

  it "server_replication_down su un primary usa la frase del primary" do
    host = create(:server_host, name: "sentinel",
                  replication_outage: { "role" => "primary", "system_identifier" => "x1" })
    content = described_class.for(event_type: "server_replication_down", subject: host)

    expect(content.title).to include("sentinel")
    # La frase del primary conta le repliche in streaming; quella dello standby parla di WAL.
    expect(content.body)
      .to eq(I18n.t("alerting.content.server_replication_down.body_primary", streaming: nil, expected: nil))
  end

  it "server_disk_forecast senza stima scrive — al posto dei giorni" do
    host = create(:server_host, name: "sentinel", disk_forecast_state: {}, resource_pressure: {})
    content = described_class.for(event_type: "server_disk_forecast", subject: host)

    expect(content.body)
      .to eq(I18n.t("alerting.content.server_disk_forecast.body", days: "—", mountpoint: "—", value: "—"))
  end

  it "server_silent senza data_age non inventa una durata" do
    host = create(:server_host, name: "sentinel", hostname: "sentinel.interno", last_seen_at: nil)
    content = described_class.for(event_type: "server_silent", subject: host)

    expect(content.body).to include("—")
  end

  it "server_container_down col motore giù avvisa sul motore, non sui nomi" do
    host = create(:server_host, name: "sentinel", hostname: nil,
                  container_outage: { "engine_down" => true })
    content = described_class.for(event_type: "server_container_down", subject: host)

    expect(content.title).to eq(I18n.t("alerting.content.server_container_down.engine_down.title", host: "sentinel"))
    expect(content.body).to eq(I18n.t("alerting.content.server_container_down.engine_down.body", hostname: "sentinel"))
  end

  it "server_container_down con un since illeggibile resta sulla frase senza durata" do
    host = create(:server_host, name: "sentinel",
                  container_outage: { "names" => [ "web" ], "since" => "boom" })
    content = described_class.for(event_type: "server_container_down", subject: host)

    # Con un since illeggibile deve restare la frase SENZA durata, non quella "…, da …".
    expect(content.body)
      .to eq(I18n.t("alerting.content.server_container_down.body", count: 1, host: "sentinel"))
  end

  # CYRA-775 — il rifiuto è dell'organizzazione (le sonde sono state respinte tutte insieme) e il
  # testo deve dire l'opposto di un guasto: le macchine non sono cadute.
  it "server_ingest_rejected è dell'organizzazione e porta alla flotta" do
    org = create(:organization)
    content = described_class.for(event_type: "server_ingest_rejected", subject: org)

    expect(content.title).to include(org.name)
    expect(content.project).to be_nil
    expect(content.url).to include("/member/monitoring/servers")
    expect(content.body).to eq(I18n.t("alerting.content.server_ingest_rejected.body"))
    expect(I18n.t("alerting.content.server_ingest_rejected.body", locale: :it)).to include("non sono cadute")
  end

  it "embedding_down è dell'organizzazione, non di un progetto" do
    org = create(:organization)
    content = described_class.for(event_type: "embedding_down", subject: org)

    expect(content.title).to include(org.name)
    expect(content.project).to be_nil
    expect(content.url).to be_present
  end

  # CYRA-712 — org-scoped come embedding_down, ma il collegamento porta ai servizi collegati: la
  # chiave sta lì, ed è l'unico posto dove chi legge l'avviso può fare qualcosa.
  it "ai_unavailable è dell'organizzazione e porta ai servizi collegati" do
    org = create(:organization)
    content = described_class.for(event_type: "ai_unavailable", subject: org)

    expect(content.title).to include(org.name)
    expect(content.project).to be_nil
    expect(content.url).to eq(Rails.application.routes.url_helpers.member_integrations_path)
  end

  it "ai_available dice che il servizio è tornato, senza ripetere il guasto" do
    org = create(:organization)
    content = described_class.for(event_type: "ai_available", subject: org)

    expect(content.title).to include(org.name)
    expect(content.title).not_to eq(described_class.for(event_type: "ai_unavailable", subject: org).title)
    expect(content.body).to be_present
  end

  it "seo_issue_new porta nel titolo il controllo e l'indirizzo" do
    issue = create(:seo_issue)
    content = described_class.for(event_type: "seo_issue_new", subject: issue)

    expect(content.title).to include(issue.label)
    expect(content.body).to be_present
    expect(content.project).to eq(issue.project)
  end

  it "runtime_eol dice quale versione smette di ricevere correzioni e da quando" do
    status = create(:vulnerability_runtime_status, name: "ruby", version: "3.4.2")
    content = described_class.for(event_type: "runtime_eol", subject: status)

    expect(content.title).to include("ruby", "3.4.2")
    expect(content.body).to be_present
    expect(content.project).to eq(status.project)
  end
end
