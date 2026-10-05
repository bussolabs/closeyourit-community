# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::Ingest::Record do
  include ActiveJob::TestHelper

  let(:project) { create(:project) }

  def payload(over = {})
    {
      "kind" => "slow_query",
      "sample_id" => SecureRandom.uuid,
      "duration_ms" => 120.0,
      "occurred_at" => Time.current.iso8601,
      "environment" => "production",
      "sql" => "SELECT * FROM users WHERE id = 42",
      "name" => "User Load",
      "db_system" => "postgresql"
    }.merge(over)
  end

  it "crea un gruppo e un sample" do
    result = described_class.call(project: project, payload: payload)
    expect(result).to be_ok
    expect(project.metric_samples.count).to eq(1)
    expect(project.metric_groups.count).to eq(1)
  end

  it "raggruppa query con la stessa signature (literal diversi)" do
    described_class.call(project: project, payload: payload("sql" => "SELECT * FROM users WHERE id = 1", "sample_id" => "a"))
    described_class.call(project: project, payload: payload("sql" => "SELECT * FROM users WHERE id = 999", "sample_id" => "b"))
    expect(project.metric_groups.count).to eq(1)
    expect(project.metric_groups.first.samples_count).to eq(2)
  end

  it "aggiorna gli aggregati di durata atomicamente" do
    described_class.call(project: project, payload: payload("duration_ms" => 100.0, "sample_id" => "a"))
    described_class.call(project: project, payload: payload("duration_ms" => 300.0, "sample_id" => "b"))
    group = project.metric_groups.first
    expect(group.samples_count).to eq(2)
    expect(group.duration_min_ms).to eq(100.0)
    expect(group.duration_max_ms).to eq(300.0)
    expect(group.duration_total_ms).to eq(400.0)
    expect(group.average_duration_ms).to eq(200.0)
  end

  it "è idempotente sullo stesso sample_id" do
    fixed = payload("sample_id" => "dup")
    described_class.call(project: project, payload: fixed)
    described_class.call(project: project, payload: fixed)
    expect(project.metric_samples.count).to eq(1)
    expect(project.metric_groups.first.samples_count).to eq(1)
  end

  it "separa slow_query e slow_method in gruppi diversi" do
    described_class.call(project: project, payload: payload("kind" => "slow_query", "sample_id" => "a"))
    described_class.call(project: project, payload: {
      "kind" => "slow_method", "sample_id" => "b", "duration_ms" => 50.0,
      "label" => "Checkout#total", "occurred_at" => Time.current.iso8601
    })
    expect(project.metric_groups.count).to eq(2)
  end

  it "ritorna err con codice R422 su kind non valido" do
    result = described_class.call(project: project, payload: payload("kind" => "bogus"))
    expect(result).to be_err
    expect(result.error.code).to match(/^R422-/)
  end

  describe "performance_issue" do
    def perf_payload(over = {})
      {
        "kind" => "performance_issue",
        "subtype" => "n_plus_one",
        "sample_id" => SecureRandom.uuid,
        "duration_ms" => 250.0,
        "occurred_at" => Time.current.iso8601,
        "environment" => "production",
        "trace_id" => "req-abc",
        "sql" => "SELECT * FROM users WHERE id = 42",
        "source" => "app/models/order.rb:42",
        "query_count" => 47
      }.merge(over)
    end

    it "crea un gruppo performance_issue con subtype + trace_id/subtype sul sample" do
      result = described_class.call(project: project, payload: perf_payload)
      expect(result).to be_ok
      group = project.metric_groups.first
      expect(group.kind).to eq("performance_issue")
      expect(group.subtype).to eq("n_plus_one")
      sample = project.metric_samples.first
      expect(sample.trace_id).to eq("req-abc")
      expect(sample.subtype).to eq("n_plus_one")
    end

    it "raggruppa N occorrenze N+1 con stesso sql+call-site (binds diversi)" do
      described_class.call(project: project, payload: perf_payload("sql" => "SELECT * FROM users WHERE id = 1", "sample_id" => "a"))
      described_class.call(project: project, payload: perf_payload("sql" => "SELECT * FROM users WHERE id = 2", "sample_id" => "b"))
      expect(project.metric_groups.count).to eq(1)
      expect(project.metric_groups.first.samples_count).to eq(2)
    end

    it "tiene separati subtype diversi" do
      described_class.call(project: project, payload: perf_payload("subtype" => "n_plus_one", "sample_id" => "a"))
      described_class.call(project: project, payload: perf_payload("subtype" => "slow_request", "route" => "X#i", "sample_id" => "b"))
      expect(project.metric_groups.count).to eq(2)
    end

    it "ritorna err R422-METRIC-003 se performance_issue senza subtype" do
      result = described_class.call(project: project, payload: perf_payload("subtype" => nil))
      expect(result).to be_err
      expect(result.error.code).to eq("R422-METRIC-003")
    end

    it "accoda Alerting::EvaluateJob (metric_threshold) quando supera la soglia di progetto" do
      project.update!(performance_alert_threshold: 1)
      expect do
        described_class.call(project: project, payload: perf_payload)
      end.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "metric_threshold", subject_type: "Metrics::Group"))
    end

    it "passa duration_ms del campione all'alerting (per le regole con threshold_ms)" do
      project.update!(performance_alert_threshold: 1)
      expect do
        described_class.call(project: project, payload: perf_payload("duration_ms" => 1234.5))
      end.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(duration_ms: 1234.5))
    end

    # CYRA-53: verdetto "a conteggio" (high_query_count). closeyourit-ruby rolla-up le query di una
    # richiesta in UN verdetto per finestra temporale e lo manda con duration_ms=0 — il peso è il NUMERO
    # di query nella finestra, non la durata. Server-side la soglia d'ingest è quindi sul CONTEGGIO di
    # occorrenze accumulate: l'alert scatta all'ATTRAVERSAMENTO di performance_alert_threshold (non al
    # 1° campione) e porta duration_ms=0 — il gate di durata lo bypassa poi Alerting::Evaluate via
    # count_based?. Pinniamo il ramo count-based dell'ingest, finora coperto solo con subtype duration-based.
    it "high_query_count (rollup a conteggio, duration_ms=0) accoda l'alert alla soglia occorrenze con duration 0" do
      project.update!(performance_alert_threshold: 2)
      hqc = { "subtype" => "high_query_count", "duration_ms" => 0.0, "route" => "OrdersController#index" }
      expect do
        described_class.call(project: project, payload: perf_payload(hqc.merge("sample_id" => "h1"))) # 1: sotto soglia
        described_class.call(project: project, payload: perf_payload(hqc.merge("sample_id" => "h2"))) # 2: attraversa
      end.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "metric_threshold", subject_type: "Metrics::Group", duration_ms: 0.0))
        .exactly(:once)
    end

    it "NON accoda alert sotto la soglia" do
      project.update!(performance_alert_threshold: 5)
      expect do
        described_class.call(project: project, payload: perf_payload)
      end.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "NON accoda alert per slow_query (solo performance_issue)" do
      expect do
        described_class.call(project: project, payload: payload)
      end.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    # CYRA-48: l'enqueue di metric_threshold è gatato sull'ATTRAVERSAMENTO della soglia, NON 1:1 col
    # volume dei campioni. Un endpoint N+1 caldo (10.000 verdetti/ora, soglia default 1) accodava un
    # EvaluateJob per campione, saturando la coda :alerts e affamando gli alert reali di errori/uptime.
    # Il guard usa la cache atomica (unless_exist), no-op sotto :null_store di test → come lo spike degli
    # errori, sostituiamo una cache reale fresca per ogni esempio.
    describe "soglia: un solo alert all'attraversamento, non 1:1 col volume (CYRA-48)" do
      before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

      it "un burst di N campioni sullo stesso gruppo accoda UN solo EvaluateJob (soglia default 1)" do
        expect do
          5.times { |i| described_class.call(project: project, payload: perf_payload("sample_id" => "b#{i}")) }
        end.to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "metric_threshold", subject_type: "Metrics::Group")).exactly(:once)
      end

      it "con soglia 3 accoda solo al campione che attraversa la soglia, non ai successivi" do
        project.update!(performance_alert_threshold: 3)
        expect do
          5.times { |i| described_class.call(project: project, payload: perf_payload("sample_id" => "t#{i}")) }
        end.to have_enqueued_job(Alerting::EvaluateJob)
          .with(hash_including(event_type: "metric_threshold")).exactly(:once)
      end

      it "sotto soglia nessun campione del burst accoda l'alert" do
        project.update!(performance_alert_threshold: 10)
        expect do
          5.times { |i| described_class.call(project: project, payload: perf_payload("sample_id" => "u#{i}")) }
        end.not_to have_enqueued_job(Alerting::EvaluateJob)
      end

      # Il flag di dedup è SCADENTE, non permanente (review Codex): se un enqueue fallisce il gruppo non
      # resta silenziato per sempre — alla scadenza del cooldown il prossimo campione oltre soglia riprova.
      it "dopo il cooldown un nuovo campione oltre soglia riaccoda (nessun silenziamento permanente)" do
        start = Time.utc(2026, 6, 1, 12)
        travel_to(start) do
          described_class.call(project: project, payload: perf_payload("sample_id" => "c1"))   # attraversa la soglia
        end
        travel_to(start + Metrics::Constants::THRESHOLD_ALERT_COOLDOWN + 1.second) do
          expect do
            described_class.call(project: project, payload: perf_payload("sample_id" => "c2"))
          end.to have_enqueued_job(Alerting::EvaluateJob)
            .with(hash_including(event_type: "metric_threshold")).exactly(:once)
        end
      end
    end
  end

  describe "race concorrenti (rescue RecordNotUnique)" do
    it "RecordNotUnique nella transazione → rescue idempotente, ritorna il sample esistente" do
      first = described_class.call(project: project, payload: payload("sample_id" => "race")).value
      relation = project.metric_samples
      allow(project).to receive(:metric_samples).and_return(relation)
      seen = 0
      allow(relation).to receive(:find_by) do |*|
        seen += 1
        seen == 1 ? nil : first
      end
      allow(ApplicationRecord).to receive(:transaction).and_raise(ActiveRecord::RecordNotUnique)

      result = described_class.call(project: project, payload: payload("sample_id" => "race"))

      expect(result).to be_ok
      expect(result.value).to eq(first)
    end

    it "race sulla creazione del gruppo: find_or_create_by! solleva RecordNotUnique → riusa l'esistente" do
      existing = create(:metric_group, project:)
      groups = project.metric_groups
      allow(project).to receive(:metric_groups).and_return(groups)
      allow(groups).to receive(:find_or_create_by!).and_raise(ActiveRecord::RecordNotUnique)
      allow(groups).to receive(:find_by!).and_return(existing)

      result = described_class.call(project: project, payload: payload("sample_id" => "grp-race"))

      expect(result).to be_ok
      expect(result.value.group_id).to eq(existing.id)
    end
  end
end
