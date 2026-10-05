# frozen_string_literal: true

require "rails_helper"

# Broadcast realtime di Metrics::Ingest::Record (CYRA-41). Dopo il commit l'ingest NON ricalcola più
# aggregati org-wide per-campione (il vecchio org_stats = group(:kind).count GROUP BY + MAX full-scan
# saturava la coda :ingest sotto burst). Emette invece un page-refresh Turbo (action="refresh") sui due
# stream toccati — lista org (metrics) e show del gruppo (metric_group) — throttlato per finestra: ogni
# viewer connesso ri-fetcha il PROPRIO URL e morpha. Gli stream sono org-prefissati da Realtime::Streams
# → isolamento tenant implicito nel nome-stream.
RSpec.describe Metrics::Ingest::Record, "broadcasts", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:metrics_stream) { Realtime::Streams.metrics(organization) }

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

  def record(over = {}) = described_class.call(project:, payload: payload(over))

  describe "page-refresh Turbo (throttlato, no aggregazioni org-wide)" do
    it "emette un page-refresh sullo stream metrics della lista org" do
      expect { record }.to have_broadcasted_to(metrics_stream)
        .with(a_string_including('action="refresh"'))
    end

    it "emette un page-refresh sullo stream della show del gruppo" do
      record("sample_id" => "first")   # crea il gruppo
      group = project.metric_groups.sole
      group_stream = Realtime::Streams.metric_group(group)

      expect { record("sample_id" => "second") }.to have_broadcasted_to(group_stream)
        .with(a_string_including('action="refresh"'))
    end

    # DoD: "Sotto burst l'ingest non esegue aggregazioni org-wide per-campione".
    it "NON esegue aggregazioni org-wide per-campione (no GROUP BY kind, no MAX della durata)" do
      create(:metric_group, project:, kind: :slow_method)   # popola l'org: un group(:kind) avrebbe da contare
      queries = captured_sql { record }

      expect(queries).not_to include(a_string_matching(/group by.*kind/i))
      expect(queries).not_to include(a_string_matching(/max\(duration_total_ms/i))
    end

    # Scenario 1: burst di campioni ravvicinati → il realtime resta aggiornato ma coalescente.
    it "coalescing sotto burst: N campioni ravvicinati = un solo leading immediato (throttle per-org)" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      expect do
        3.times { |i| record("sample_id" => "burst-#{i}") }   # stesso fingerprint → stesso gruppo
      end.to have_broadcasted_to(metrics_stream).once
    end

    # Il trailing garantisce che lo stato di FINE burst sia mostrato anche se i campioni si esauriscono
    # dentro la finestra (un leading-edge puro lascerebbe la UI ferma al primo campione).
    it "coalescing sotto burst: i campioni dopo il leading schedulano un refresh trailing" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      record("sample_id" => "lead")   # leading immediato

      expect { record("sample_id" => "tail") }   # trailing a fine finestra
        .to have_enqueued_job(Realtime::BroadcastRefreshJob).with(metrics_stream)
    end
  end

  describe "idempotenza" do
    it "non broadcasta di nuovo su sample_id già registrato" do
      fixed = payload("sample_id" => "dup")
      described_class.call(project:, payload: fixed)
      expect { described_class.call(project:, payload: fixed) }
        .not_to have_broadcasted_to(metrics_stream)
    end
  end

  describe "errori (nessun broadcast)" do
    it "kind non valido → nessun broadcast" do
      expect { record("kind" => "bogus") }.not_to have_broadcasted_to(metrics_stream)
    end
  end

  describe "isolamento tenant" do
    it "non broadcasta sullo stream metrics di un'ALTRA organizzazione" do
      other = Realtime::Streams.metrics(create(:organization))
      expect { record }.not_to have_broadcasted_to(other)
    end
  end
end
