require "rails_helper"

RSpec.describe "CloseYourIt initializer" do
  subject(:configuration) { CloseYourIt.configuration }

  it "uses the conservative self-monitoring profile" do
    expect(configuration).to have_attributes(
      slow_query_threshold_ms: 250,
      capture_handled_errors: true,
      report_active_job_errors: true,
      capture_rails_logs: true,
      capture_rails_logs_min_level: :warn,
      detect_performance_issues: false,
      send_pii: false,
      capture_request_body: false,
      capture_query_bindings: false,
      capture_method_arguments: false
    )
  end

  it "drops slow-query events that touch the internal telemetry tables" do
    internal_payloads = [
      { "kind" => "slow_query", "sql" => "INSERT INTO \"errors_events\" (\"id\") VALUES (?)" },
      { "kind" => "slow_query", "sql" => "UPDATE \"errors_groups\" SET \"count\" = ? WHERE \"id\" = ?" },
      { "kind" => "slow_query", "sql" => "INSERT INTO \"metrics_samples\" (\"id\") VALUES (?)" },
      { "kind" => "slow_query", "sql" => "SELECT * FROM \"errors_events\" WHERE \"project_id\" = ? AND \"event_id\" = ?" },
      { "kind" => "slow_query", "sql" => "INSERT INTO \"logs_entries\" (\"id\") VALUES (?)" }
    ]

    internal_payloads.each do |payload|
      expect(configuration.before_send.call(payload)).to be_nil
    end
  end

  it "keeps slow-query events for product tables" do
    payload = { "kind" => "slow_query", "sql" => "SELECT * FROM \"members\" WHERE \"id\" = ?" }

    expect(configuration.before_send.call(payload)).to eq(payload)
  end

  it "keeps non slow-query events untouched" do
    payload = { "kind" => "error", "message" => "boom" }

    expect(configuration.before_send.call(payload)).to eq(payload)
  end

  # CYRA-849 — anello di retroazione del 2026-09-16. La corsia `ingest` va sopra il minuto di attesa, la
  # gemma emette un `job_queue_latency` per OGNI job servito, e quella misura si spedisce come un
  # nuovo Metrics::IngestJob sulla STESSA corsia: guadagno 1:1, la coda non rientra mai da sola
  # (16.000 arretrati, 16 minuti di ritardo sui dati dei server, allarmi «dati fermi» falsi su tutta
  # la flotta). Stessa forma del loop Solid Cable già chiuso da `excluded_exceptions`.
  it "scarta le metriche dei job della corsia di ricezione dati" do
    [ "job_queue_latency", "slow_job" ].each do |subtype|
      payload = {
        "kind" => "performance_issue", "subtype" => subtype,
        "label" => "Metrics::IngestJob", "queue" => "ingest", "duration_ms" => 1_120_015.33
      }

      expect(configuration.before_send.call(payload)).to be_nil
    end
  end

  it "tiene le metriche dei job di ogni altra corsia" do
    payload = {
      "kind" => "performance_issue", "subtype" => "job_queue_latency",
      "label" => "Uptime::CheckJob", "queue" => "uptime", "duration_ms" => 61_000.0
    }

    expect(configuration.before_send.call(payload)).to eq(payload)
  end

  # Gli altri performance_issue (n_plus_one, slow_request, high_query_count) non portano `queue`:
  # la guardia non deve mangiarseli.
  it "tiene i rilievi di performance che non riguardano un job" do
    payload = { "kind" => "performance_issue", "subtype" => "n_plus_one", "label" => "TicketsController#index" }

    expect(configuration.before_send.call(payload)).to eq(payload)
  end

  it "does not raise slow_query_threshold_ms to hide the noise" do
    expect(configuration.slow_query_threshold_ms).to eq(250)
  end

  it "is disabled when the ingest token is missing" do
    candidate = CloseYourIt::Configuration.new
    candidate.endpoint_url = "https://ingest.example.com"
    candidate.project_id = "e3e38dc6-eef3-4bb6-b95c-5af54c2936b3"
    candidate.environment = "production"
    candidate.token = nil

    expect(candidate).not_to be_enabled
  end
end
