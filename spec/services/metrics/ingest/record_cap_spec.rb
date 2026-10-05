# frozen_string_literal: true

require "rails_helper"

# CYRA-196 — Tetto per gruppo, gemello di quello sugli errori: oltre soglia la riga si scrive comunque
# ma senza `payload`. Tenere la riga è ciò che lascia a `insert_all` il suo giro di dedup col RETURNING,
# quindi conteggio e aggregati restano esatti anche su un lotto ri-consegnato.
#
# L'API accetta sia un campione singolo sia un array: il tetto deve valere per ENTRAMBE le forme — uno
# che copre solo il batch non è un tetto.
RSpec.describe Metrics::Ingest::Record, "tetto per gruppo (CYRA-196)", type: :service do
  let(:project) { create(:project) }

  def payload(sample_id, duration_ms: 120.0)
    {
      "kind" => "slow_query",
      "sample_id" => sample_id,
      "duration_ms" => duration_ms,
      "occurred_at" => Time.current.iso8601,
      "environment" => "production",
      "sql" => "SELECT * FROM users WHERE id = 42"
    }
  end

  def cap!(count) = stub_const("Monitoring::Constants::TELEMETRY_FULL_FIDELITY_COUNT", count)

  describe "path a campione SINGOLO" do
    it "sotto il tetto conserva il payload" do
      cap!(10)
      described_class.call(project: project, payload: payload("a"))

      expect(project.metric_groups.sole.samples.sole.payload).to be_present
    end

    it "oltre il tetto scrive la riga senza payload" do
      cap!(1)
      described_class.call(project: project, payload: payload("a"))
      described_class.call(project: project, payload: payload("b"))

      group = project.metric_groups.sole
      expect(group.samples_count).to eq(2)
      expect(group.samples.count).to eq(2)
      expect(group.samples.order(:created_at).last.payload).to eq({})
    end
  end

  describe "path BATCH" do
    it "sotto il tetto conserva il payload di ogni campione" do
      cap!(10)
      described_class.call_batch(project: project, payloads: [ payload("a"), payload("b") ])

      expect(project.metric_groups.sole.samples.map { |s| s.payload.present? }).to eq([ true, true ])
    end

    it "oltre il tetto scrive tutte le righe senza payload" do
      cap!(1)
      described_class.call_batch(project: project, payloads: [ payload("a") ])
      described_class.call_batch(project: project, payloads: [ payload("b"), payload("c") ])

      group = project.metric_groups.sole
      expect(group.samples_count).to eq(3)
      expect(group.samples.count).to eq(3)
      expect(group.samples.where(sample_id: %w[b c]).map(&:payload)).to all(eq({}))
    end
  end

  describe "invarianti che la riga tiene in piedi" do
    it "un lotto ri-consegnato non ri-conta negli aggregati, nemmeno oltre il tetto" do
      cap!(1)
      described_class.call_batch(project: project, payloads: [ payload("a", duration_ms: 100.0) ])
      body = [ payload("b", duration_ms: 200.0) ]
      described_class.call_batch(project: project, payloads: body)
      described_class.call_batch(project: project, payloads: body)   # replay: no-op

      group = project.metric_groups.sole
      expect(group.samples_count).to eq(2)
      expect(group.duration_total_ms).to eq(300.0)
    end

    it "gli aggregati di durata restano fedeli oltre il tetto" do
      cap!(1)
      described_class.call_batch(project: project, payloads: [ payload("a", duration_ms: 100.0) ])
      described_class.call_batch(project: project, payloads: [
        payload("b", duration_ms: 50.0), payload("c", duration_ms: 4_400.0)
      ])

      group = project.metric_groups.sole
      expect(group.samples_count).to eq(3)
      expect(group.duration_min_ms).to eq(50.0)
      expect(group.duration_max_ms).to eq(4_400.0)
      expect(group.duration_total_ms).to eq(4_550.0)
    end

    # METRICS_MAX_BATCH è 1.000: se `drop_body` fosse deciso una volta per lotto sul contatore
    # pre-bump, un lotto a cavallo della soglia conserverebbe fino a 999 payload oltre il tetto.
    it "in un lotto a cavallo della soglia il corpo cade dalla riga giusta in poi" do
      cap!(2)
      described_class.call_batch(project: project, payloads: [
        payload("a"), payload("b"), payload("c"), payload("d")
      ])

      group = project.metric_groups.sole
      expect(group.samples.find_by(sample_id: "a").payload).to be_present   # posto 0 → sotto il tetto
      expect(group.samples.find_by(sample_id: "b").payload).to be_present   # posto 1 → sotto il tetto
      expect(group.samples.find_by(sample_id: "c").payload).to eq({})       # posto 2 → tetto raggiunto
      expect(group.samples.find_by(sample_id: "d").payload).to eq({})
    end

    it "il conteggio degli accettati resta quello dei campioni nuovi" do
      cap!(1)
      described_class.call_batch(project: project, payloads: [ payload("a") ])
      result = described_class.call_batch(project: project, payloads: [ payload("b"), payload("c") ])

      expect(result.value.accepted).to eq(2)
    end
  end
end
