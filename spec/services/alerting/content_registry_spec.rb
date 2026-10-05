# frozen_string_literal: true

require "rails_helper"

# CYRA-797 — rete di caratterizzazione del registro degli avvisi. Per OGNI tipo gestito congela le
# chiavi i18n interrogate (titolo, testo e le loro varianti), il link, il progetto e i dettagli:
# un ramo perso o dirottato su un'altra chiave cade qui, non in una notifica già partita.
RSpec.describe Alerting::Content do
  let(:project) { create(:project) }
  let(:organization) { create(:organization, name: "Acme") }

  let(:host) do
    create(:server_host, name: "apps", hostname: "apps.internal",
           cpu_pct: 95.5, mem_pct: 91.0, disk_pct: 88.2, temp_max: 84.0,
           last_seen_at: 20.minutes.ago,
           failed_services: %w[backup.service],
           smart_data: { "nvme0" => { "status" => "FAILED" }, "sda" => { "status" => "PASSED" } },
           security_updates_available: 4,
           database_snapshot: { "connections" => { "total" => 90, "max" => 100, "reserved" => 5 },
                                "replication" => { "streaming" => false, "lag_seconds" => 42.5 } },
           resource_pressure: {
             "data_volume_disk" => { "name" => "pgdata", "mountpoint" => "/mnt/pgdata", "pct" => 91.2 },
             "inode" => { "name" => "root", "mountpoint" => "/", "pct" => 88.0 }
           },
           replication_outage: { "role" => "standby", "expected" => 1, "streaming" => 0 },
           disk_forecast_state: { "days" => 9.5, "current_pct" => 81.0 },
           container_outage: { "names" => %w[web], "since" => 2.hours.ago.iso8601 },
           container_restart_outage: { "containers" => [ { "name" => "worker", "restarts" => 4 } ] })
  end

  # Il link della scheda host è lo stesso per tutti i server_*: si scrive una volta.
  let(:host_url) { "/member/monitoring/servers/#{host.id}" }

  # Solo le chiavi di questo dominio: le durate ("20 minuti fa") e i formati di data li produce i18n
  # per conto suo e non fanno parte del contratto del registro.
  def contract_keys(used)
    used.select { |key| key.start_with?("alerting.", "member.") }.uniq.sort
  end

  def build(event_type, subject_record)
    used = []
    allow(I18n).to receive(:t).and_wrap_original do |original, key, **options|
      used << key.to_s
      original.call(key, **options)
    end
    content = described_class.for(event_type: event_type, subject: subject_record)
    [ content, contract_keys(used) ]
  end

  cases = [
    { event_type: "measurement_threshold",
      subject: -> { Alerting::Evaluation.new(project: project, result: { "name" => "temperature", "statistic" => "last", "value" => "10", "unit" => "Cel", "threshold" => "5", "comparison" => "gt", "diagnostics" => [] }) },
      keys: %w[alerting.content.measurement_threshold.title alerting.content.measurement_threshold.body alerting.measurements.statistics.last],
      url: ->(s) { "/member/projects/#{s.project_id}" },
      project: ->(s) { s.project }, details: { "threshold" => "5", "comparison" => "gt", "diagnostics" => [] } },
    { event_type: "error_new",
      subject: -> { create(:error_group, project:, culprit: "App#call") },
      keys: %w[alerting.content.error_new.title],
      url: ->(s) { "/member/monitoring/error/#{s.id}" },
      project: ->(s) { s.project }, details: nil },
    { event_type: "error_spike",
      subject: -> { create(:error_group, project:, culprit: "App#call") },
      keys: %w[alerting.content.error_spike.title],
      url: ->(s) { "/member/monitoring/error/#{s.id}" },
      project: ->(s) { s.project }, details: nil },
    { name: "error_regression (con la release che ha causato il rientro)",
      event_type: "error_regression",
      subject: -> { create(:error_group, project:, culprit: "App#call", regressed_in_release: "v2.0") },
      keys: %w[alerting.content.error_regression.release alerting.content.error_regression.title],
      url: ->(s) { "/member/monitoring/error/#{s.id}" },
      project: ->(s) { s.project }, details: nil },
    { event_type: "uptime_down",
      subject: -> { create(:uptime_incident, monitor: create(:uptime_monitor, project:)) },
      keys: %w[alerting.content.uptime_down.body alerting.content.uptime_down.title],
      url: ->(s) { "/member/monitoring/monitors/#{s.monitor.id}" },
      project: ->(s) { s.monitor.project }, details: nil },
    { event_type: "uptime_up",
      subject: -> { create(:uptime_incident, :resolved, monitor: create(:uptime_monitor, project:)) },
      keys: %w[alerting.content.uptime_up.body alerting.content.uptime_up.title],
      url: ->(s) { "/member/monitoring/monitors/#{s.monitor.id}" },
      project: ->(s) { s.monitor.project }, details: nil },
    { name: "cron_missed (con un check-in alle spalle)",
      event_type: "cron_missed",
      subject: -> { create(:cron_monitor, project:, last_check_in_at: 4.days.ago, expected_interval_minutes: 2) },
      keys: %w[alerting.content.cron_missed.body alerting.content.cron_missed.title],
      url: ->(_s) { "/member/monitoring/cron" },
      project: ->(s) { s.project }, details: nil },
    { name: "cron_missed (atteso ma mai arrivato)",
      event_type: "cron_missed",
      subject: -> { create(:cron_monitor, project:, last_check_in_at: nil, expected_interval_minutes: 2) },
      keys: %w[alerting.content.cron_missed.body_never alerting.content.cron_missed.title],
      url: ->(_s) { "/member/monitoring/cron" },
      project: ->(s) { s.project }, details: nil },
    { event_type: "uptime_ssl_expiring",
      subject: -> { create(:uptime_monitor, project:, ssl_expires_at: 10.days.from_now) },
      keys: %w[alerting.content.uptime_ssl_expiring.body alerting.content.uptime_ssl_expiring.title],
      url: ->(s) { "/member/monitoring/monitors/#{s.id}" },
      project: ->(s) { s.project }, details: nil },
    { event_type: "uptime_slow",
      subject: -> { create(:uptime_monitor, project:, latency_threshold_ms: 500) },
      keys: %w[alerting.content.uptime_slow.body alerting.content.uptime_slow.title],
      url: ->(s) { "/member/monitoring/monitors/#{s.id}" },
      project: ->(s) { s.project }, details: nil },
    { event_type: "metric_threshold",
      subject: -> { create(:metric_group, :performance_issue, project:, title: "N+1 SELECT users") },
      keys: ->(s) { [ "alerting.content.metric_threshold.title", "member.metrics.subtype.#{s.subtype}" ] },
      url: ->(s) { "/member/monitoring/performance/#{s.id}" },
      project: ->(s) { s.project }, details: nil },
    { event_type: "server_down", subject: -> { host },
      keys: %w[alerting.content.server_down.body alerting.content.server_down.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_up", subject: -> { host },
      keys: %w[alerting.content.server_up.body alerting.content.server_up.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_cpu", subject: -> { host },
      keys: %w[alerting.content.server_cpu.body alerting.content.server_cpu.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_mem", subject: -> { host },
      keys: %w[alerting.content.server_mem.body alerting.content.server_mem.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_disk", subject: -> { host },
      keys: %w[alerting.content.server_disk.body alerting.content.server_disk.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_temp", subject: -> { host },
      keys: %w[alerting.content.server_temp.body alerting.content.server_temp.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_service_failed", subject: -> { host },
      keys: %w[alerting.content.server_service_failed.body alerting.content.server_service_failed.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: %w[backup.service] },
    { event_type: "server_db_down", subject: -> { host },
      keys: %w[alerting.content.server_db_down.body alerting.content.server_db_down.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_db_connections", subject: -> { host },
      keys: %w[alerting.content.server_db_connections.body alerting.content.server_db_connections.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_db_connection_usage", subject: -> { host },
      keys: %w[alerting.content.server_db_connection_usage.body
               alerting.content.server_db_connection_usage.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_replication_lag", subject: -> { host },
      keys: %w[alerting.content.server_replication_lag.body alerting.content.server_replication_lag.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_data_volume_disk", subject: -> { host },
      keys: %w[alerting.content.server_data_volume_disk.body alerting.content.server_data_volume_disk.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: %w[pgdata] },
    { event_type: "server_inode", subject: -> { host },
      keys: %w[alerting.content.server_inode.body alerting.content.server_inode.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: %w[root] },
    { name: "server_replication_down (standby)", event_type: "server_replication_down", subject: -> { host },
      keys: %w[alerting.content.server_replication_down.body_standby
               alerting.content.server_replication_down.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { name: "server_replication_down (primary)", event_type: "server_replication_down",
      subject: -> { host.tap { |h| h.update!(replication_outage: { "role" => "primary" }) } },
      keys: %w[alerting.content.server_replication_down.body_primary
               alerting.content.server_replication_down.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_replication_up", subject: -> { host },
      keys: %w[alerting.content.server_replication_up.body alerting.content.server_replication_up.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_disk_forecast", subject: -> { host },
      keys: %w[alerting.content.server_disk_forecast.body alerting.content.server_disk_forecast.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_security_updates", subject: -> { host },
      keys: %w[alerting.content.server_security_updates.body alerting.content.server_security_updates.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_silent", subject: -> { host },
      keys: %w[alerting.content.server_silent.body alerting.content.server_silent.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_smart_failing", subject: -> { host },
      keys: %w[alerting.content.server_smart_failing.body alerting.content.server_smart_failing.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: %w[nvme0] },
    { name: "server_container_down (con la durata dell'assenza)", event_type: "server_container_down",
      subject: -> { host },
      keys: %w[alerting.content.server_container_down.body_since alerting.content.server_container_down.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: %w[web] },
    { name: "server_container_down (senza durata)", event_type: "server_container_down",
      subject: -> { host.tap { |h| h.update!(container_outage: { "names" => %w[web] }) } },
      keys: %w[alerting.content.server_container_down.body alerting.content.server_container_down.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: %w[web] },
    { name: "server_container_down (motore giù)", event_type: "server_container_down",
      subject: -> { host.tap { |h| h.update!(container_outage: { "engine_down" => true }) } },
      keys: %w[alerting.content.server_container_down.engine_down.body
               alerting.content.server_container_down.engine_down.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_container_up", subject: -> { host },
      keys: %w[alerting.content.server_container_up.body alerting.content.server_container_up.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_container_restart_loop", subject: -> { host },
      keys: %w[alerting.content.server_container_restart_loop.body
               alerting.content.server_container_restart_loop.detail
               alerting.content.server_container_restart_loop.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: :any },
    { event_type: "server_container_stable", subject: -> { host },
      keys: %w[alerting.content.server_container_stable.body alerting.content.server_container_stable.title],
      url: ->(_s) { host_url }, project: ->(_s) { nil }, details: nil },
    { event_type: "log_alert",
      subject: -> { create(:log_entry, project:, level: :fatal, message: "payment gateway unreachable") },
      keys: ->(s) { [ "alerting.content.log_alert.title", "member.alerting.levels.#{s.level}" ] },
      url: ->(s) { "/member/monitoring/logs/#{s.id}" },
      project: ->(s) { s.project }, details: nil },
    { event_type: "embedding_down", subject: -> { organization },
      keys: %w[alerting.content.embedding_down.body alerting.content.embedding_down.title],
      url: ->(_s) { "/member/agents" }, project: ->(_s) { nil }, details: nil },
    { event_type: "ai_unavailable", subject: -> { organization },
      keys: %w[alerting.content.ai_unavailable.body alerting.content.ai_unavailable.title],
      url: ->(_s) { "/member/integrations" }, project: ->(_s) { nil }, details: nil },
    { event_type: "ai_available", subject: -> { organization },
      keys: %w[alerting.content.ai_available.body alerting.content.ai_available.title],
      url: ->(_s) { "/member/integrations" }, project: ->(_s) { nil }, details: nil },
    { event_type: "cache_unavailable", subject: -> { organization },
      keys: %w[alerting.content.cache_unavailable.body alerting.content.cache_unavailable.title],
      url: ->(_s) { "/member/monitoring/servers" }, project: ->(_s) { nil }, details: nil },
    { event_type: "server_ingest_rejected", subject: -> { organization },
      keys: %w[alerting.content.server_ingest_rejected.body alerting.content.server_ingest_rejected.title],
      url: ->(_s) { "/member/monitoring/servers" }, project: ->(_s) { nil }, details: nil },
    # CYAG-22: Kubernetes clusters link to the cluster page.
    { event_type: "cluster_down", subject: -> { create(:cluster, organization:) },
      keys: %w[alerting.content.cluster_down.body alerting.content.cluster_down.title],
      url: ->(s) { "/member/monitoring/clusters/#{s.id}" }, project: ->(_s) { nil }, details: nil },
    { event_type: "cluster_up", subject: -> { create(:cluster, organization:) },
      keys: %w[alerting.content.cluster_up.body alerting.content.cluster_up.title],
      url: ->(s) { "/member/monitoring/clusters/#{s.id}" }, project: ->(_s) { nil }, details: nil },
    { event_type: "cluster_node_not_ready", subject: -> { create(:cluster_node) },
      keys: %w[alerting.content.cluster_node_not_ready.body alerting.content.cluster_node_not_ready.title],
      url: ->(s) { "/member/monitoring/clusters/#{s.cluster_id}" }, project: ->(_s) { nil }, details: nil },
    { event_type: "cluster_node_pressure", subject: -> { create(:cluster_node) },
      keys: %w[alerting.content.cluster_node_pressure.body alerting.content.cluster_node_pressure.title],
      url: ->(s) { "/member/monitoring/clusters/#{s.cluster_id}" }, project: ->(_s) { nil }, details: nil },
    { event_type: "cluster_workload_crashloop", subject: -> { create(:cluster_workload, last_reason: "OOMKilled") },
      keys: %w[alerting.content.cluster_workload_crashloop.body alerting.content.cluster_workload_crashloop.title],
      url: ->(s) { "/member/monitoring/clusters/#{s.cluster_id}" }, project: ->(_s) { nil }, details: nil },
    { event_type: "cluster_workload_degraded", subject: -> { create(:cluster_workload, desired: 3, ready: 1) },
      keys: %w[alerting.content.cluster_workload_degraded.body alerting.content.cluster_workload_degraded.title],
      url: ->(s) { "/member/monitoring/clusters/#{s.cluster_id}" }, project: ->(_s) { nil }, details: nil },
    { event_type: "agents_stalled", subject: -> { organization },
      keys: %w[alerting.content.agents_stalled.body alerting.content.agents_stalled.title],
      url: ->(_s) { "/member/agents" }, project: ->(_s) { nil }, details: nil },
    { event_type: "agents_host_failing", subject: -> { create(:agent_host, hostname: "minion-1.local") },
      keys: %w[alerting.content.agents_host_failing.body alerting.content.agents_host_failing.title],
      url: ->(s) { "/member/agents/#{s.id}" }, project: ->(_s) { nil }, details: nil },
    { event_type: "agents_host_stale", subject: -> { create(:agent_host, hostname: "minion-2.local") },
      keys: %w[alerting.content.agents_host_stale.body alerting.content.agents_host_stale.title],
      url: ->(s) { "/member/agents/#{s.id}" }, project: ->(_s) { nil }, details: nil },
    { name: "vulnerability_new (con una versione che risolve)", event_type: "vulnerability_new",
      subject: -> { create(:vulnerability_finding) },
      keys: ->(s) {
        [ "alerting.content.vulnerability_new.body", "alerting.content.vulnerability_new.title",
          "member.monitoring.vulnerabilities.severity.#{s.severity}" ]
      },
      url: ->(s) { "/member/monitoring/vulnerabilities/#{s.id}" },
      project: ->(s) { s.project }, details: nil },
    { name: "vulnerability_new (nessun aggiornamento da suggerire)", event_type: "vulnerability_new",
      subject: -> { create(:vulnerability_finding, :unfixable) },
      keys: ->(s) {
        [ "alerting.content.vulnerability_new.body_unfixable", "alerting.content.vulnerability_new.title",
          "member.monitoring.vulnerabilities.severity.#{s.severity}" ]
      },
      url: ->(s) { "/member/monitoring/vulnerabilities/#{s.id}" },
      project: ->(s) { s.project }, details: nil },
    { event_type: "seo_issue_new", subject: -> { create(:seo_issue) },
      keys: :any,
      url: ->(s) { "/member/monitoring/seo/#{s.id}" },
      project: ->(s) { s.project }, details: nil },
    { event_type: "runtime_eol", subject: -> { create(:vulnerability_runtime_status, :eol) },
      keys: %w[alerting.content.runtime_eol.body alerting.content.runtime_eol.title],
      url: ->(_s) { "/member/monitoring/vulnerabilities/runtimes" },
      project: ->(s) { s.project }, details: nil },
    { event_type: "secret_read",
      subject: -> { create(:secret_event, project:, action: "read", name: "API_KEY") },
      keys: ->(_s) {
        [ "alerting.content.secret_access.any_environment", "alerting.content.secret_access.system",
          "alerting.content.secret_read.body", "alerting.content.secret_read.title" ]
      },
      url: ->(s) { "/member/projects/#{s.project.id}/secrets/audit" },
      project: ->(s) { s.project }, details: nil },
    { event_type: "secret_denied",
      subject: -> { create(:secret_event, project:, action: "denied", name: "API_KEY") },
      keys: ->(_s) {
        [ "alerting.content.secret_access.any_environment", "alerting.content.secret_access.system",
          "alerting.content.secret_denied.body", "alerting.content.secret_denied.title" ]
      },
      url: ->(s) { "/member/projects/#{s.project.id}/secrets/audit" },
      project: ->(s) { s.project }, details: nil },
    { event_type: "analytics_traffic_drop", subject: -> { project },
      keys: %w[alerting.content.analytics_traffic_drop.body alerting.content.analytics_traffic_drop.title],
      url: ->(s) { "/member/monitoring/analytics?project_id=#{s.id}" },
      project: ->(s) { s }, details: nil },
    { event_type: "analytics_traffic_spike", subject: -> { project },
      keys: %w[alerting.content.analytics_traffic_spike.body alerting.content.analytics_traffic_spike.title],
      url: ->(s) { "/member/monitoring/analytics?project_id=#{s.id}" },
      project: ->(s) { s }, details: nil },
    { event_type: "idea_created", subject: -> { create(:idea) },
      keys: %w[alerting.content.idea_created.title],
      url: ->(s) { "/member/ideas/#{s.id}" }, project: ->(s) { s.project }, details: nil },
    { event_type: "idea_commented", subject: -> { create(:idea_comment) },
      keys: %w[alerting.content.idea_commented.title],
      url: ->(s) { "/member/ideas/#{s.idea.id}" }, project: ->(s) { s.idea.project }, details: nil },
    { event_type: "workload_due_soon", subject: -> { create(:workload_action) },
      keys: %w[alerting.content.workload_due_soon.body alerting.content.workload_due_soon.title],
      url: ->(s) { "/member/workload/actions/#{s.id}" }, project: ->(_s) { nil }, details: nil },
    { event_type: "dataset_training_completed", subject: -> { create(:dataset_training, :done) },
      keys: %w[alerting.content.dataset_training_completed.body
               alerting.content.dataset_training_completed.title],
      url: ->(s) { "/member/datasets/#{s.dataset.id}/trainings/#{s.id}" },
      project: ->(s) { s.dataset.project }, details: nil },
    { name: "dataset_training_failed (col messaggio d'errore)", event_type: "dataset_training_failed",
      subject: -> { create(:dataset_training, :failed) },
      keys: %w[alerting.content.dataset_training_failed.title],
      url: ->(s) { "/member/datasets/#{s.dataset.id}/trainings/#{s.id}" },
      project: ->(s) { s.dataset.project }, details: nil },
    { name: "dataset_training_failed (senza messaggio)", event_type: "dataset_training_failed",
      subject: -> { create(:dataset_training, :failed, error_message: nil) },
      keys: %w[alerting.content.dataset_training_failed.body alerting.content.dataset_training_failed.title],
      url: ->(s) { "/member/datasets/#{s.dataset.id}/trainings/#{s.id}" },
      project: ->(s) { s.dataset.project }, details: nil }
  ]

  cases.each do |scenario|
    it "#{scenario[:name] || scenario[:event_type]}: stesse chiavi, stesso link, stesso progetto" do
      subject_record = instance_exec(&scenario[:subject])
      content, used = build(scenario[:event_type], subject_record)

      expected_keys = scenario[:keys]
      unless expected_keys == :any
        expected_keys = instance_exec(subject_record, &expected_keys) if expected_keys.respond_to?(:call)
        expect(used).to eq(expected_keys.sort)
      end

      expect(content.title).to be_present
      expect(content.body).to be_present
      expect([ content.title, content.body ].join(" ")).not_to include("translation missing", "%{")
      expect(content.url).to eq(instance_exec(subject_record, &scenario[:url]))
      # The stored notification composes the same link from its subject, not from the frozen string.
      stored = Alerting::Notification.new(event_type: scenario[:event_type], subject: subject_record,
                                          project: content.project, url: "/stale")
      expect(stored.url).to eq(content.url)
      expect(content.project).to eq(instance_exec(subject_record, &scenario[:project]))
      expect(content.details).to eq(scenario[:details]) unless scenario[:details] == :any
    end
  end

  it "un tipo sconosciuto resta un errore, non un avviso muto" do
    expect { described_class.for(event_type: "boom", subject: project) }
      .to raise_error(ArgumentError, /boom/)
  end

  # CYRA-797 Scenario 2 — aggiungere un avviso deve costare un metodo piccolo e una riga di registro.
  # Queste due prove sono la definizione operativa di "piccolo" e di "registro".
  describe "il registro degli avvisi" do
    it "nomina esattamente i tipi che il costruttore sa costruire" do
      expect(described_class::EVENT_BUILDERS.keys.sort).to eq(cases.map { |c| c[:event_type] }.uniq.sort)
    end

    it "manda ogni tipo a un metodo di famiglia che esiste e resta privato" do
      described_class::EVENT_BUILDERS.each_value do |builder|
        expect(described_class.private_methods(false)).to include(builder)
      end
    end

    it "non lascia più un metodo lungo quanto il vecchio case" do
      source = Rails.root.join("app/services/alerting/content.rb").readlines
      too_long = method_bodies(source).select { |_name, body| body.size > 20 }

      expect(too_long.keys).to be_empty,
        "metodi oltre 20 righe di codice: #{too_long.transform_values(&:size).inspect}"
    end
  end

  # Righe di CODICE fra `def` e la sua `end` (stessa indentazione): commenti e righe vuote non
  # contano — la regola misura quanto c'è da seguire, non quanto c'è scritto.
  def method_bodies(lines)
    bodies = {}
    open_name = nil
    open_indent = nil
    lines.each do |line|
      # Un metodo di una riga (`def x = ...`) non apre nulla: non ha una `end` da cercare.
      next if line.match?(/^\s*def (?:self\.)?[\w?!]+(?:\([^)]*\))?\s*=/)

      if open_name.nil? && (match = line.match(/^(\s*)def (?:self\.)?([\w?!]+)/))
        open_indent = match[1]
        open_name = match[2]
        bodies[open_name] = []
      elsif open_name
        if line == "#{open_indent}end\n"
          open_name = nil
        elsif line.strip.present? && !line.strip.start_with?("#")
          bodies[open_name] << line
        end
      end
    end
    bodies
  end
end
