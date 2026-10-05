# frozen_string_literal: true

require "rails_helper"

# Batch ingest delle metriche (CYRA-43). Un POST con N campioni deve produrre UN solo job che
# raggruppa i campioni per fingerprint e applica gli incrementi aggregati con un solo UPDATE per
# gruppo (parità con Logs::Ingest::Record) — non N transazioni/broadcast. Contratto: call_batch
# ritorna Result.ok(Summary) con accepted + rejected (per il logging del job).
RSpec.describe Metrics::Ingest::Record, "#call_batch", type: :service do
  include ActiveJob::TestHelper

  let(:project) { create(:project) }

  def payload(over = {})
    {
      "kind" => "slow_query",
      "sample_id" => SecureRandom.uuid,
      "duration_ms" => 120.0,
      "occurred_at" => Time.current.iso8601,
      "environment" => "production",
      "sql" => "SELECT * FROM users WHERE id = 42"
    }.merge(over)
  end

  it "un batch di N campioni con lo stesso fingerprint crea 1 gruppo con samples_count = N" do
    body = [ payload("sample_id" => "a"), payload("sample_id" => "b"), payload("sample_id" => "c") ]
    result = described_class.call_batch(project: project, payloads: body)

    expect(result).to be_ok
    expect(project.metric_groups.count).to eq(1)
    expect(project.metric_groups.sole.samples_count).to eq(3)
    expect(project.metric_samples.count).to eq(3)
  end

  it "gli aggregati di durata sono corretti dopo il batch (min/max/total/avg)" do
    body = [
      payload("sample_id" => "a", "duration_ms" => 100.0),
      payload("sample_id" => "b", "duration_ms" => 300.0),
      payload("sample_id" => "c", "duration_ms" => 200.0)
    ]
    described_class.call_batch(project: project, payloads: body)

    group = project.metric_groups.sole
    expect(group.samples_count).to eq(3)
    expect(group.duration_min_ms).to eq(100.0)
    expect(group.duration_max_ms).to eq(300.0)
    expect(group.duration_total_ms).to eq(600.0)
    expect(group.average_duration_ms).to eq(200.0)
  end

  # DoD: "Gli aggregati per gruppo sono corretti dopo il batch" == identici al processo per-campione.
  it "gli aggregati del batch coincidono con quelli del processo per-campione" do
    other = create(:project, organization: project.organization)
    durations = [ 100.0, 300.0, 250.0, 90.0 ]
    durations.each_with_index do |d, i|
      described_class.call(project: other, payload: payload("sample_id" => "s#{i}", "duration_ms" => d))
    end

    described_class.call_batch(
      project: project,
      payloads: durations.each_with_index.map { |d, i| payload("sample_id" => "b#{i}", "duration_ms" => d) }
    )

    single = other.metric_groups.sole
    batch = project.metric_groups.sole
    expect(batch.samples_count).to eq(single.samples_count)
    expect(batch.duration_min_ms).to eq(single.duration_min_ms)
    expect(batch.duration_max_ms).to eq(single.duration_max_ms)
    expect(batch.duration_total_ms).to eq(single.duration_total_ms)
  end

  it "raggruppa fingerprint diversi in gruppi distinti, ognuno con i suoi aggregati" do
    body = [
      payload("sample_id" => "q1", "kind" => "slow_query", "sql" => "SELECT * FROM users WHERE id = 1", "duration_ms" => 100.0),
      payload("sample_id" => "q2", "kind" => "slow_query", "sql" => "SELECT * FROM users WHERE id = 2", "duration_ms" => 200.0),
      { "kind" => "slow_method", "sample_id" => "m1", "duration_ms" => 50.0,
        "label" => "Checkout#total", "occurred_at" => Time.current.iso8601 }
    ]
    described_class.call_batch(project: project, payloads: body)

    expect(project.metric_groups.count).to eq(2)
    query_group = project.metric_groups.find_by(kind: :slow_query)
    method_group = project.metric_groups.find_by(kind: :slow_method)
    expect(query_group.samples_count).to eq(2)
    expect(query_group.duration_total_ms).to eq(300.0)
    expect(method_group.samples_count).to eq(1)
  end

  # DoD: "Un solo update per gruppo" — non N update sotto burst dello stesso fingerprint.
  it "esegue UN SOLO UPDATE su metrics_groups per gruppo (non uno per campione)" do
    body = Array.new(5) { |i| payload("sample_id" => "u#{i}") }   # stesso fingerprint
    queries = captured_sql { described_class.call_batch(project: project, payloads: body) }

    updates = queries.count { |q| q.match?(/UPDATE\s+"metrics_groups"/i) }
    expect(updates).to eq(1)
  end

  it "è idempotente sui sample_id duplicati DENTRO lo stesso batch" do
    body = [ payload("sample_id" => "dup"), payload("sample_id" => "dup"), payload("sample_id" => "other") ]
    described_class.call_batch(project: project, payloads: body)

    expect(project.metric_samples.count).to eq(2)
    expect(project.metric_groups.sole.samples_count).to eq(2)
  end

  it "è idempotente sui sample_id già presenti nel DB (replay): non doppia gli aggregati" do
    described_class.call(project: project, payload: payload("sample_id" => "seen", "duration_ms" => 100.0))
    described_class.call_batch(project: project, payloads: [
      payload("sample_id" => "seen", "duration_ms" => 100.0),   # già registrato
      payload("sample_id" => "fresh", "duration_ms" => 300.0)
    ])

    group = project.metric_groups.sole
    expect(project.metric_samples.count).to eq(2)
    expect(group.samples_count).to eq(2)
    expect(group.duration_total_ms).to eq(400.0)
    expect(group.duration_max_ms).to eq(300.0)
  end

  # Regressione (review Codex): un replay con sample_id già presente ma fingerprint DIVERSO non deve
  # lasciare un gruppo vuoto orfano (upsert_group avviene prima che insert_all scarti il duplicato).
  # Le asserzioni interrogano il model direttamente (stato DB reale): find_or_create_by! sull'associazione
  # lascerebbe il gruppo rollbackato nel target in-memory, falsando project.metric_groups.
  it "un replay con sample_id già presente ma fingerprint diverso NON crea un gruppo vuoto" do
    described_class.call(project: project, payload: payload("sample_id" => "X", "sql" => "SELECT * FROM users WHERE id = 1"))
    expect(Metrics::Group.where(project_id: project.id).count).to eq(1)

    described_class.call_batch(project: project, payloads: [
      { "kind" => "slow_method", "sample_id" => "X", "duration_ms" => 50.0,
        "label" => "Other#method", "occurred_at" => Time.current.iso8601 }   # fingerprint nuovo, sample_id già visto
    ])

    groups = Metrics::Group.where(project_id: project.id)
    expect(groups.count).to eq(1)   # nessun gruppo slow_method fantasma persistito
    expect(groups.sole.kind).to eq("slow_query")
    expect(Metrics::Sample.where(project_id: project.id).count).to eq(1)
  end

  it "un batch dove ogni fingerprint ha solo campioni duplicati non crea alcun gruppo nuovo" do
    described_class.call(project: project, payload: payload("sample_id" => "dup", "sql" => "SELECT * FROM a WHERE id = 1"))
    groups_before = Metrics::Group.where(project_id: project.id).count

    result = described_class.call_batch(project: project, payloads: [
      { "kind" => "slow_method", "sample_id" => "dup", "duration_ms" => 10.0, "label" => "B#m", "occurred_at" => Time.current.iso8601 }
    ])

    expect(result.value.accepted).to eq(0)
    expect(Metrics::Group.where(project_id: project.id).count).to eq(groups_before)
  end

  it "scarta i campioni con kind invalido e li riporta in rejected, processando gli altri" do
    body = [ payload("sample_id" => "ok"), payload("sample_id" => "ko", "kind" => "bogus") ]
    result = described_class.call_batch(project: project, payloads: body)

    expect(result).to be_ok
    expect(result.value.accepted).to eq(1)
    expect(result.value.rejected).to eq([ "R422-METRIC-002" ])
    expect(project.metric_samples.count).to eq(1)
  end

  it "persiste per i campioni performance_issue tutti i campi ricchi (subtype/trace_id/payload jsonb)" do
    perf = {
      "kind" => "performance_issue", "subtype" => "n_plus_one", "sample_id" => "p-rich",
      "duration_ms" => 320.0, "occurred_at" => Time.current.iso8601, "trace_id" => "req-xyz",
      "environment" => "production", "sql" => "SELECT * FROM orders WHERE user_id = 7",
      "source" => "app/models/user.rb:10", "query_count" => 50
    }
    described_class.call_batch(project: project, payloads: [ perf ])

    sample = project.metric_samples.sole
    expect(sample.subtype).to eq("n_plus_one")
    expect(sample.trace_id).to eq("req-xyz")
    expect(sample.kind).to eq("performance_issue")
    expect(sample.payload["query_count"]).to eq(50)
    expect(project.metric_groups.sole.subtype).to eq("n_plus_one")
  end

  it "scarta performance_issue senza subtype (R422-METRIC-003)" do
    perf = {
      "kind" => "performance_issue", "sample_id" => "p1", "duration_ms" => 250.0,
      "occurred_at" => Time.current.iso8601, "sql" => "SELECT 1"
    }
    result = described_class.call_batch(project: project, payloads: [ perf ])

    expect(result.value.accepted).to eq(0)
    expect(result.value.rejected).to eq([ "R422-METRIC-003" ])
    expect(project.metric_samples.count).to eq(0)
  end

  it "batch vuoto → nessun gruppo, accepted 0" do
    result = described_class.call_batch(project: project, payloads: [])
    expect(result).to be_ok
    expect(result.value.accepted).to eq(0)
    expect(project.metric_groups.count).to eq(0)
  end

  describe "fonte (sdk)" do
    it "registra la fonte UNA sola volta per batch dall'sdk dei campioni" do
      body = Array.new(3) do |i|
        payload("sample_id" => "s#{i}").merge("sdk" => { "name" => "closeyourit-ruby", "version" => "0.4.0" })
      end
      described_class.call_batch(project: project, payloads: body)

      source = project.sources.find_by!(tool_code: "closeyourit-ruby")
      expect(source.version).to eq("0.4.0")
      expect(project.sources.count).to eq(1)
    end
  end

  describe "alerting" do
    def perf_payload(over = {})
      {
        "kind" => "performance_issue", "subtype" => "n_plus_one", "sample_id" => SecureRandom.uuid,
        "duration_ms" => 250.0, "occurred_at" => Time.current.iso8601, "environment" => "production",
        "sql" => "SELECT * FROM users WHERE id = 42", "source" => "app/models/order.rb:42"
      }.merge(over)
    end

    it "accoda UN SOLO Alerting::EvaluateJob per gruppo quando il batch supera la soglia (non uno per campione)" do
      project.update!(performance_alert_threshold: 2)
      body = [ perf_payload("sample_id" => "a"), perf_payload("sample_id" => "b"), perf_payload("sample_id" => "c") ]

      expect do
        described_class.call_batch(project: project, payloads: body)
      end.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "metric_threshold", subject_type: "Metrics::Group")).once
    end

    it "NON accoda alert se il batch resta sotto la soglia" do
      project.update!(performance_alert_threshold: 5)
      body = [ perf_payload("sample_id" => "a"), perf_payload("sample_id" => "b") ]

      expect do
        described_class.call_batch(project: project, payloads: body)
      end.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "NON accoda alert per slow_query" do
      body = [ payload("sample_id" => "a"), payload("sample_id" => "b") ]
      expect do
        described_class.call_batch(project: project, payloads: body)
      end.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    # CYRA-48: batch successivi sullo stesso gruppo caldo NON devono accodare un alert per batch — solo
    # il primo che attraversa la soglia. Il guard usa la cache atomica (unless_exist), no-op sotto
    # :null_store → cache reale fresca per questo esempio.
    it "batch successivi sullo stesso gruppo oltre soglia accodano UN solo alert totale (non uno per batch)" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      project.update!(performance_alert_threshold: 1)

      expect do
        described_class.call_batch(project: project, payloads: [ perf_payload("sample_id" => "a1"), perf_payload("sample_id" => "a2") ])
        described_class.call_batch(project: project, payloads: [ perf_payload("sample_id" => "b1"), perf_payload("sample_id" => "b2") ])
      end.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "metric_threshold", subject_type: "Metrics::Group")).exactly(:once)
    end
  end

  describe "broadcast realtime" do
    it "emette il page-refresh sullo stream metrics dell'org (una sola volta, throttlato)" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      stream = Realtime::Streams.metrics(project.organization)
      body = Array.new(3) { |i| payload("sample_id" => "b#{i}") }

      expect { described_class.call_batch(project: project, payloads: body) }
        .to have_broadcasted_to(stream).with(a_string_including('action="refresh"'))
    end
  end
end
