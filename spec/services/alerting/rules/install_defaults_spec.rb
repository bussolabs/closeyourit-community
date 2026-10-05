# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Rules::InstallDefaults, type: :service do
  let(:organization) { create(:organization) }

  # Eventi org-scoped senza soglia che ogni org deve avere pronti senza configurazione manuale:
  # server (macchina della flotta) e agenti di automazione (CYRA-242).
  let(:server_default_events) do
    %w[server_down server_up server_service_failed server_smart_failing
       server_container_down server_container_up server_db_down
       server_replication_down server_replication_up
       server_container_restart_loop server_container_stable
       server_security_updates server_silent server_disk_forecast
       server_ingest_rejected]
  end
  # CYAG-22: Kubernetes clusters watched by closeyourit-kube.
  let(:cluster_default_events) do
    %w[cluster_down cluster_up cluster_node_not_ready cluster_node_pressure
       cluster_workload_crashloop cluster_workload_degraded]
  end
  let(:capacity_default_events) do
    %w[server_db_connection_usage server_data_volume_disk server_inode]
  end
  let(:org_scoped_default_events) do
    server_default_events + capacity_default_events + cluster_default_events +
      %w[agents_stalled agents_host_failing agents_host_stale]
  end
  # CYRA-147: statistiche (solo crollo, il picco è opt-in), idee, attività, dataset.
  let(:cyra147_default_events) do
    %w[analytics_traffic_drop idea_created idea_commented workload_due_soon
       dataset_training_completed dataset_training_failed]
  end
  # CYRA-506: sicurezza delle dipendenze. Project-scoped come gli errori, senza soglia — il filtro di
  # gravità sta su min_level della regola, non sull'elenco dei default.
  let(:vulnerability_default_events) { %w[vulnerability_new runtime_eol] }
  # CYRA-875: CloseYourIt's own services are platform alerts for the gods, never a customer default.
  let(:service_default_events) { %w[embedding_down ai_unavailable ai_available cache_unavailable] }
  # CYRA-528: il rilievo SEO grave. Project-scoped come gli errori.
  let(:seo_default_events) { %w[seo_issue_new] }
  let(:all_default_events) do
    %w[uptime_down uptime_up uptime_slow cron_missed] + org_scoped_default_events +
      cyra147_default_events + vulnerability_default_events + seo_default_events
  end

  it "does not install the internal service alerts in a customer organization (CYRA-875)" do
    described_class.call(organization: organization)

    expect(Alerting::Rule.where(organization: organization, event_type: service_default_events)).to be_empty
  end

  it "crea le regole di default per uptime, server, agenti e servizi interni" do
    described_class.call(organization: organization)
    types = Alerting::Rule.where(organization: organization).map(&:event_type)
    expect(types).to contain_exactly(*all_default_events)
  end

  it "crea le regole di default per statistiche, idee, attività e dataset (CYRA-147), attive" do
    described_class.call(organization: organization)

    cyra147_default_events.each do |event|
      rule = Alerting::Rule.find_by(organization: organization, event_type: event)
      expect(rule).to be_present, "manca la regola di default #{event}"
      expect(rule).to be_enabled
    end
  end

  it "NON installa il picco di traffico di default (opt-in)" do
    described_class.call(organization: organization)
    expect(Alerting::Rule.where(organization: organization, event_type: :analytics_traffic_spike)).not_to exist
  end

  it "la regola uptime_down è attiva e org-wide (copre tutti i monitor)" do
    described_class.call(organization: organization)
    rule = Alerting::Rule.find_by(organization: organization, event_type: :uptime_down)
    expect(rule).to be_enabled
    expect(rule.project_id).to be_nil
    expect(rule.environment_id).to be_nil
  end

  # CYRA-477: cron_missed era l'unico evento monitor SENZA regola di default → un job che si fermava
  # non avvisava nessuno. Ora è org-wide e attiva come uptime_down, così ogni org nasce coperta.
  it "la regola cron_missed è attiva e org-wide (nessun lavoro programmato nasce scoperto)" do
    described_class.call(organization: organization)
    rule = Alerting::Rule.find_by(organization: organization, event_type: :cron_missed)
    expect(rule).to be_enabled
    expect(rule.project_id).to be_nil
    expect(rule.environment_id).to be_nil
  end

  it "la caduta di un server ha una regola pronta: server_down attiva, org-wide, senza soglia" do
    described_class.call(organization: organization)
    rule = Alerting::Rule.find_by(organization: organization, event_type: :server_down)
    expect(rule).to be_enabled
    expect(rule.project_id).to be_nil
    expect(rule.environment_id).to be_nil
    expect(rule.threshold).to be_nil
  end

  it "installa tutte le regole server e la regola agenti org-wide e attive" do
    described_class.call(organization: organization)

    org_scoped_default_events.each do |event|
      rule = Alerting::Rule.find_by(organization: organization, event_type: event)
      expect(rule).to be_present, "manca la regola di default #{event}"
      expect(rule).to be_enabled
      expect(rule.project_id).to be_nil
      expect(rule.environment_id).to be_nil
    end
  end

  # CYRA-450: una macchina ferma resta ferma; col rilevamento ogni 15' il throttle di default (5') la
  # ri-notificherebbe di continuo → la regola nasce con throttle a 1h, mentre le altre restano al default.
  it "la regola agents_host_stale nasce con throttle a 1h, le altre al default" do
    described_class.call(organization: organization)

    stale = Alerting::Rule.find_by(organization: organization, event_type: :agents_host_stale)
    failing = Alerting::Rule.find_by(organization: organization, event_type: :agents_host_failing)
    expect(stale.throttle_seconds).to eq(3600)
    expect(failing.throttle_seconds).to eq(300)
  end

  # CYRA-775: il giro che giudica la salute gira ogni minuto e un episodio di rifiuti dura decine di
  # minuti — col throttle di default lo stesso avviso arriverebbe una volta al minuto.
  it "la regola sui dati respinti nasce con throttle a 1h" do
    described_class.call(organization: organization)

    rule = Alerting::Rule.find_by(organization: organization, event_type: :server_ingest_rejected)
    expect(rule.throttle_seconds).to eq(3600)
  end

  it "installa solo i guardrail di capacità con soglie esplicite" do
    expect { described_class.call(organization: organization) }.not_to raise_error

    rules = Alerting::Rule.where(organization: organization, event_type: Alerting::Rule::THRESHOLD_EVENT_TYPES)
                          .index_by(&:event_type)
    expect(rules.keys).to contain_exactly(*capacity_default_events)
    expect(rules["server_db_connection_usage"].threshold).to eq(80)
    expect(rules["server_data_volume_disk"].threshold).to eq(85)
    expect(rules["server_inode"].threshold).to eq(80)
  end

  it "è idempotente (rieseguibile senza duplicare)" do
    2.times { described_class.call(organization: organization) }
    expect(Alerting::Rule.where(organization: organization).count).to eq(all_default_events.size)
  end

  it "non tocca una regola uptime_down org-wide già configurata a mano, anche se disabilitata" do
    existing = create(:alerting_rule, :uptime_down, :disabled, organization: organization, name: "La mia")
    described_class.call(organization: organization)

    downs = Alerting::Rule.where(organization: organization, event_type: :uptime_down)
    expect(downs.count).to eq(1)
    expect(existing.reload).not_to be_enabled
    expect(existing.name).to eq("La mia")
  end

  it "non tocca una regola server_down org-wide già configurata a mano, anche se disabilitata" do
    existing = create(:alerting_rule, :server_down, :disabled, organization: organization, name: "Il mio server")
    described_class.call(organization: organization)

    downs = Alerting::Rule.where(organization: organization, event_type: :server_down)
    expect(downs.count).to eq(1)
    expect(existing.reload).not_to be_enabled
    expect(existing.name).to eq("Il mio server")
  end

  it "non duplica una regola server_down già esistente scoped (Evaluate ignora lo scope → la valuta su tutta l'org)" do
    scoped = create(:alerting_rule, :server_down, :scoped, organization: organization)
    described_class.call(organization: organization)

    downs = Alerting::Rule.where(organization: organization, event_type: :server_down)
    expect(downs.count).to eq(1)
    expect(downs.first).to eq(scoped)
    expect(Alerting::Rule.where(organization: organization, event_type: :server_down,
                                project_id: nil, environment_id: nil)).not_to exist
  end

  it "installa la regola org-wide anche se ne esiste una scoped su un progetto (gli altri monitor resterebbero scoperti)" do
    create(:alerting_rule, :uptime_down, :scoped, organization: organization)
    described_class.call(organization: organization)

    org_wide = Alerting::Rule.where(organization: organization, event_type: :uptime_down,
                                    project_id: nil, environment_id: nil)
    expect(org_wide.count).to eq(1)
    expect(org_wide.first).to be_enabled
  end

  it "installa la regola org-wide anche se ne esiste una scoped su un ambiente" do
    environment = create(:environment, organization: organization)
    create(:alerting_rule, :uptime_down, organization: organization, environment: environment)
    described_class.call(organization: organization)

    expect(Alerting::Rule.where(organization: organization, event_type: :uptime_down,
                                project_id: nil, environment_id: nil)).to exist
  end

  it "assegna created_by quando passato" do
    account = create(:account)
    described_class.call(organization: organization, created_by: account)
    expect(Alerting::Rule.find_by(organization: organization, event_type: :uptime_down).created_by).to eq(account)
  end

  it "ritorna Result.ok con l'organizzazione" do
    result = described_class.call(organization: organization)
    expect(result).to be_ok
    expect(result.value).to eq(organization)
  end
end
