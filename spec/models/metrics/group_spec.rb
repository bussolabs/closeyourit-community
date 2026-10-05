# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::Group, type: :model do
  it "richiede fingerprint, title e kind" do
    group = build(:metric_group, fingerprint: nil, title: nil)
    expect(group).not_to be_valid
    expect(group.errors[:fingerprint]).to be_present
    expect(group.errors[:title]).to be_present
  end

  it "ha fingerprint unico per progetto" do
    existing = create(:metric_group)
    dup = build(:metric_group, project: existing.project, fingerprint: existing.fingerprint)
    expect(dup).not_to be_valid
  end

  it "permette lo stesso fingerprint in progetti diversi" do
    create(:metric_group, fingerprint: "same")
    other = build(:metric_group, fingerprint: "same")
    expect(other).to be_valid
  end

  it "espone l'enum kind slow_query/slow_method/performance_issue" do
    expect(described_class.kinds.keys).to contain_exactly("slow_query", "slow_method", "performance_issue")
  end

  it "scope performance_issues filtra solo i verdetti di performance" do
    perf = create(:metric_group, :performance_issue, fingerprint: "perf")
    slow = create(:metric_group, fingerprint: "slow")
    expect(described_class.performance_issues).to include(perf)
    expect(described_class.performance_issues).not_to include(slow)
  end

  it "distrugge i sample dipendenti" do
    group = create(:metric_group)
    create(:metric_sample, group: group, project: group.project)
    expect { group.destroy }.to change(Metrics::Sample, :count).by(-1)
  end

  it "calcola average_duration_ms = total / count" do
    group = build(:metric_group, samples_count: 4, duration_total_ms: 200.0)
    expect(group.average_duration_ms).to eq(50.0)
  end

  it "average_duration_ms è 0 senza sample" do
    group = build(:metric_group, samples_count: 0, duration_total_ms: 0.0)
    expect(group.average_duration_ms).to eq(0.0)
  end

  describe "#count_based? (verdetti a conteggio, CYRA-39)" do
    Metrics::Group::COUNT_BASED_SUBTYPES.each do |subtype|
      it "è true per il subtype a conteggio #{subtype}" do
        expect(build(:metric_group, kind: :performance_issue, subtype: subtype).count_based?).to be(true)
      end
    end

    it "è false per un subtype duration-based (slow_request)" do
      expect(build(:metric_group, kind: :performance_issue, subtype: "slow_request").count_based?).to be(false)
    end

    it "è false quando il subtype è assente (slow_query/slow_method)" do
      expect(build(:metric_group, subtype: nil).count_based?).to be(false)
    end
  end

  describe "link al ticket promosso" do
    it "belongs_to :ticket opzionale (class Ticketing::Ticket)" do
      assoc = described_class.reflect_on_association(:ticket)
      expect(assoc.macro).to eq(:belongs_to)
      expect(assoc.options[:optional]).to be(true)
      expect(assoc.options[:class_name]).to eq("Ticketing::Ticket")
    end

    it "promoted? riflette la presenza del ticket" do
      expect(build(:metric_group).promoted?).to be(false)
      expect(build(:metric_group, ticket_id: SecureRandom.uuid).promoted?).to be(true)
    end
  end

  describe ".buckets_for" do
    let(:now) { Time.zone.local(2026, 6, 27, 22, 0, 0) }
    let(:group) { create(:metric_group) }

    around { |ex| travel_to(now) { ex.run } }

    def sample_at(minutes_ago, duration)
      create(:metric_sample, group: group, project: group.project,
                             occurred_at: now - minutes_ago.minutes, duration_ms: duration)
    end

    it "un now con i nanosecondi non sposta i blocchi di uno: l'ultimo resta quello corrente" do
      odd_now = Time.utc(2026, 6, 27, 12, 0, Rational(1_234_567_891, 1_000_000_000))
      create(:metric_sample, group: group, project: group.project, occurred_at: odd_now - 5.minutes, duration_ms: 100)

      buckets = described_class.buckets_for(group.id, "24h", odd_now)[group.id]
      expect(buckets.last[:count]).to eq(1)
      expect(buckets[-2][:status]).to eq(:empty)
    end

    it "ritorna esattamente N blocchi per il range (30m → 30 × 1min)" do
      buckets = described_class.buckets_for(group.id, "30m")[group.id]
      expect(buckets.size).to eq(30)
    end

    it "ritorna {} quando la lista di id è vuota (ids.blank?)" do
      expect(described_class.buckets_for([], "30m")).to eq({})
    end

    it "i blocchi senza occorrenza sono :empty" do
      sample_at(5, 100)
      buckets = described_class.buckets_for(group.id, "30m")[group.id]
      expect(buckets.count { |b| b[:status] == :empty }).to eq(29)
    end

    it "classifica per soglia avg ai confini 149/150 e 499/500" do
      sample_at(25, 149)  # :fast   (< 150)
      sample_at(20, 150)  # :medium (= 150)
      sample_at(15, 499)  # :medium (< 500)
      sample_at(10, 500)  # :slow   (= 500)
      buckets = described_class.buckets_for(group.id, "30m")[group.id]
      filled = buckets.reject { |b| b[:status] == :empty }.map { |b| [ b[:avg_ms], b[:status] ] }
      expect(filled).to contain_exactly([ 149, :fast ], [ 150, :medium ], [ 499, :medium ], [ 500, :slow ])
    end

    it "porta count e avg_ms per blocco" do
      sample_at(10, 200)
      sample_at(10, 400) # stesso minuto → stesso blocco: avg 300, count 2
      buckets = described_class.buckets_for(group.id, "30m")[group.id]
      bucket = buckets.find { |b| b[:status] != :empty }
      expect(bucket[:count]).to eq(2)
      expect(bucket[:avg_ms]).to eq(300)
    end
  end

  describe "#duration_percentiles (CYRA-146: i casi peggiori, non solo la media)" do
    let(:group) { create(:metric_group) }

    def sample(duration)
      create(:metric_sample, group: group, project: group.project, duration_ms: duration)
    end

    it "senza campioni ritorna p50/p95/p99 tutti nil" do
      expect(group.duration_percentiles).to eq(50 => nil, 95 => nil, 99 => nil)
    end

    it "calcola p50/p95/p99 con percentile_cont (interpolazione continua)" do
      [ 10, 20, 30 ].each { |ms| sample(ms) }
      pct = group.duration_percentiles
      expect(pct[50]).to eq(20.0)
      expect(pct[95]).to be_within(0.001).of(29.0)
      expect(pct[99]).to be_within(0.001).of(29.8)
      expect(pct[50]).to be <= pct[95]
      expect(pct[95]).to be <= pct[99]
    end

    # Scenario 1 del ticket: veloce in media, lento per pochi. La media (≈269ms) nasconde la coda;
    # p99 la rende visibile.
    it "rivela la coda lenta che la media nasconde (95 campioni veloci + 5 lentissimi)" do
      95.times { sample(20) }
      5.times  { sample(5000) }
      pct = group.duration_percentiles
      expect(pct[50]).to eq(20.0)
      expect(pct[99]).to be >= 5000
    end

    it "accetta una lista di percentili custom (single-percentile → chiave sola)" do
      [ 100, 200, 300, 400 ].each { |ms| sample(ms) }
      pct = group.duration_percentiles([ 90 ])
      expect(pct.keys).to eq([ 90 ])
      expect(pct[90]).to be_within(0.001).of(370.0)
    end
  end

  describe ".duration_status" do
    it { expect(described_class.duration_status(nil)).to eq(:empty) }
    it { expect(described_class.duration_status(149)).to eq(:fast) }
    it { expect(described_class.duration_status(300)).to eq(:medium) }
    it { expect(described_class.duration_status(900)).to eq(:slow) }

    # CYRA-341: le soglie sono un'impostazione del progetto, non più due numeri cablati.
    it "con le soglie del progetto classifica sui valori scelti lì" do
      soglie = { fast: 20, slow: 60 }
      expect(described_class.duration_status(19, soglie)).to eq(:fast)
      expect(described_class.duration_status(20, soglie)).to eq(:medium)
      expect(described_class.duration_status(60, soglie)).to eq(:slow)
    end
  end

  # CYRA-341 — «sta peggiorando?» era la domanda a cui la scheda non rispondeva: c'era la media di
  # sempre e il conteggio delle occorrenze, mai la durata nel tempo.
  describe ".duration_buckets_for (andamento della durata, p50/p95 per blocco)" do
    let(:now) { Time.zone.local(2026, 6, 27, 22, 0, 0) }
    let(:group) { create(:metric_group) }

    around { |ex| travel_to(now) { ex.run } }

    def sample_at(minutes_ago, duration)
      create(:metric_sample, group: group, project: group.project,
                             occurred_at: now - minutes_ago.minutes, duration_ms: duration)
    end

    it "un now con i nanosecondi non sposta i blocchi di uno: l'ultimo resta quello corrente" do
      odd_now = Time.utc(2026, 6, 27, 12, 0, Rational(1_234_567_891, 1_000_000_000))
      create(:metric_sample, group: group, project: group.project, occurred_at: odd_now - 5.minutes, duration_ms: 100)

      buckets = described_class.duration_buckets_for(group.id, "24h", odd_now)
      expect(buckets.last[:count]).to eq(1)
      expect(buckets[-2][:status]).to eq(:empty)
    end

    it "ritorna esattamente N blocchi per il range (30m → 30 × 1min)" do
      expect(described_class.duration_buckets_for(group.id, "30m").size).to eq(30)
    end

    it "i blocchi senza campioni restano vuoti (nessuna durata inventata)" do
      sample_at(5, 100)
      buckets = described_class.duration_buckets_for(group.id, "30m")

      expect(buckets.count { |b| b[:status] == :empty }).to eq(29)
      expect(buckets.select { |b| b[:status] == :empty }.map { |b| b[:p95] }.uniq).to eq([ nil ])
    end

    it "porta p50 e p95 per blocco (la coda lenta che la media nasconde)" do
      9.times { sample_at(10, 20) }
      sample_at(10, 5_000) # stesso minuto → stesso blocco

      bucket = described_class.duration_buckets_for(group.id, "30m").find { |b| b[:status] != :empty }
      expect(bucket[:count]).to eq(10)
      expect(bucket[:p50]).to eq(20)
      expect(bucket[:p95]).to be >= 2_000
    end

    it "colora il blocco sul p95 con le soglie del progetto" do
      sample_at(10, 300)

      lenta = described_class.duration_buckets_for(group.id, "30m", now, thresholds: { fast: 500, slow: 900 })
      stretta = described_class.duration_buckets_for(group.id, "30m", now, thresholds: { fast: 50, slow: 100 })
      expect(lenta.find { |b| b[:status] != :empty }[:status]).to eq(:fast)
      expect(stretta.find { |b| b[:status] != :empty }[:status]).to eq(:slow)
    end

    it "ignora i campioni fuori dalla finestra del range" do
      sample_at(120, 900) # 2 ore fa, fuori dai 30 minuti

      expect(described_class.duration_buckets_for(group.id, "30m").all? { |b| b[:status] == :empty }).to be(true)
    end
  end

  describe "#duration_trend (confronto col periodo precedente della stessa lunghezza)" do
    let(:now) { Time.zone.local(2026, 6, 27, 22, 0, 0) }
    let(:group) { create(:metric_group) }

    around { |ex| travel_to(now) { ex.run } }

    def sample_at(hours_ago, duration)
      create(:metric_sample, group: group, project: group.project,
                             occurred_at: now - hours_ago.hours, duration_ms: duration)
    end

    it "confronta le ultime 24 ore con le 24 precedenti" do
      sample_at(2, 800)
      sample_at(3, 820)
      sample_at(30, 600)
      sample_at(40, 600)

      trend = group.duration_trend("24h", now)
      expect(trend[:current_ms]).to eq(810)
      expect(trend[:previous_ms]).to eq(600)
      expect(trend[:delta_pct]).to eq(35)
    end

    it "un rallentamento che raddoppia vale +100%" do
      sample_at(1, 1_000)
      sample_at(30, 500)

      expect(group.duration_trend("24h", now)[:delta_pct]).to eq(100)
    end

    it "un miglioramento ha delta negativo" do
      sample_at(1, 250)
      sample_at(30, 500)

      expect(group.duration_trend("24h", now)[:delta_pct]).to eq(-50)
    end

    it "senza dati nel periodo precedente non inventa un confronto" do
      sample_at(1, 900)

      trend = group.duration_trend("24h", now)
      expect(trend[:current_ms]).to eq(900)
      expect(trend[:previous_ms]).to be_nil
      expect(trend[:delta_pct]).to be_nil
    end

    it "senza campioni in nessuno dei due periodi resta tutto vuoto" do
      trend = group.duration_trend("24h", now)

      expect(trend).to eq(current_ms: nil, previous_ms: nil, delta_pct: nil)
    end

    it "un periodo precedente a durata zero non produce un delta (nessuna divisione per zero)" do
      sample_at(1, 900)
      create(:metric_sample, group: group, project: group.project, occurred_at: now - 30.hours, duration_ms: 0)

      expect(group.duration_trend("24h", now)[:delta_pct]).to be_nil
    end

    it "il range decide la lunghezza delle due finestre (30m → 30 minuti contro i 30 prima)" do
      create(:metric_sample, group: group, project: group.project, occurred_at: now - 10.minutes, duration_ms: 400)
      create(:metric_sample, group: group, project: group.project, occurred_at: now - 40.minutes, duration_ms: 200)

      trend = group.duration_trend("30m", now)
      expect(trend[:current_ms]).to eq(400)
      expect(trend[:previous_ms]).to eq(200)
      expect(trend[:delta_pct]).to eq(100)
    end
  end

  # CYRA-339: la media su pochissimi campioni non è un segnale → le righe vanno marcate come poco
  # significative. Soglia LOW_SAMPLE_THRESHOLD (20).
  describe "#low_sample?" do
    it "true sotto la soglia (media distorta da pochi casi)" do
      expect(build(:metric_group, samples_count: 19).low_sample?).to be(true)
    end

    it "false alla soglia e oltre" do
      expect(build(:metric_group, samples_count: 20).low_sample?).to be(false)
      expect(build(:metric_group, samples_count: 500).low_sample?).to be(false)
    end

    it "la soglia esposta è 20" do
      expect(described_class::LOW_SAMPLE_THRESHOLD).to eq(20)
    end
  end

  # CYRA-339: ordinare per costo complessivo (durata totale = media × occorrenze) mette in cima il
  # collo di bottiglia vero, non il picco raro capitato una o due volte.
  describe ".costliest_first" do
    it "ordina per durata totale decrescente (bottleneck reale prima del caso raro)" do
      rare = create(:metric_group, fingerprint: "rare", samples_count: 2, duration_total_ms: 2_000.0)
      bottleneck = create(:metric_group, fingerprint: "bottleneck", samples_count: 100_000, duration_total_ms: 81_000_000.0)
      expect(described_class.costliest_first.to_a).to eq([ bottleneck, rare ])
    end

    # I verdetti a conteggio (repeated_http/rebuild_storm/high_query_count) hanno durata 0 per contratto:
    # a parità di durata il più frequente non deve finire in fondo in ordine arbitrario.
    it "a parità di durata (es. verdetti a conteggio, durata 0) mette prima il più frequente" do
      rare = create(:metric_group, fingerprint: "cb-rare", duration_total_ms: 0.0, samples_count: 5)
      frequent = create(:metric_group, fingerprint: "cb-frequent", duration_total_ms: 0.0, samples_count: 900)
      expect(described_class.costliest_first.to_a).to eq([ frequent, rare ])
    end

    it "tie-breaker id deterministico a parità di durata e di occorrenze" do
      a = create(:metric_group, fingerprint: "a", duration_total_ms: 1_000.0, samples_count: 3)
      b = create(:metric_group, fingerprint: "b", duration_total_ms: 1_000.0, samples_count: 3)
      expect(described_class.costliest_first.to_a).to eq([ a, b ].sort_by(&:id).reverse)
    end
  end
end
