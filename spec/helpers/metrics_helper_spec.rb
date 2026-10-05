# frozen_string_literal: true

require "rails_helper"

RSpec.describe MetricsHelper, type: :helper do
  describe "#metric_kind_color" do
    it { expect(helper.metric_kind_color("slow_query")).to eq(:sky) }
    it { expect(helper.metric_kind_color("slow_method")).to eq(:violet) }
    it { expect(helper.metric_kind_color("boh")).to eq(:gray) }
  end

  # CYRA-342: label leggibile e localizzata del kind (categoria). Serve a disambiguare la dimensione
  # «Categoria» dalla dimensione «Tipo di problema» (subtype) e a comporre la gerarchia della card.
  describe "#metric_kind_label" do
    it "traduce i kind in italiano" do
      I18n.with_locale(:it) do
        expect(helper.metric_kind_label("slow_query")).to eq("Query lenta")
        expect(helper.metric_kind_label("slow_method")).to eq("Metodo lento")
        expect(helper.metric_kind_label("performance_issue")).to eq("Problema di performance")
      end
    end

    it "traduce i kind in inglese" do
      I18n.with_locale(:en) do
        expect(helper.metric_kind_label("slow_query")).to eq("Slow query")
        expect(helper.metric_kind_label("performance_issue")).to eq("Performance issue")
      end
    end

    it "kind sconosciuto → stringa grezza (fallback, nessun crash)" do
      expect(helper.metric_kind_label("boh")).to eq("boh")
    end
  end

  # CYRA-343: la signature LEGGIBILE per la vista. Nei verdetti performance_issue il `title`
  # serializzato inizia col subtype grezzo (es. "n_plus_one SELECT …"): quel prefisso tecnico è già
  # reso come badge localizzato a parte, qui va tolto dalla resa a video (mai dal valore serializzato).
  describe "#metric_display_signature" do
    def group(kind:, title:, subtype: nil)
      instance_double(Metrics::Group,
                      kind_performance_issue?: kind == "performance_issue", subtype: subtype, title: title)
    end

    it "verdetto performance_issue: toglie il prefisso del subtype dalla resa" do
      g = group(kind: "performance_issue", subtype: "n_plus_one",
                title: "n_plus_one SELECT * FROM users WHERE id = <n> app/models/order.rb:42")
      expect(helper.metric_display_signature(g))
        .to eq("SELECT * FROM users WHERE id = <n> app/models/order.rb:42")
    end

    it "high_query_count: toglie il prefisso e lascia la route leggibile" do
      g = group(kind: "performance_issue", subtype: "high_query_count",
                title: "high_query_count Api::V1::MapController#markers")
      expect(helper.metric_display_signature(g)).to eq("Api::V1::MapController#markers")
    end

    it "metrica raw (slow_query): signature invariata, nessun prefisso da togliere" do
      g = group(kind: "slow_query", title: "SELECT * FROM users WHERE id = ?")
      expect(helper.metric_display_signature(g)).to eq("SELECT * FROM users WHERE id = ?")
    end

    it "performance_issue il cui title non inizia col subtype: invariato (difensivo)" do
      g = group(kind: "performance_issue", subtype: "n_plus_one", title: "N+1 on Order#items")
      expect(helper.metric_display_signature(g)).to eq("N+1 on Order#items")
    end

    it "mai la sola parola grezza: title uguale al solo subtype → etichetta leggibile" do
      g = group(kind: "performance_issue", subtype: "jank", title: "jank")
      expect(I18n.with_locale(:it) { helper.metric_display_signature(g) }).to eq("Jank (frame lento)")
    end
  end

  # CYRA-343: riga di spiegazione «in parole semplici» sotto ogni voce dei filtri Categoria/Tipo.
  describe "#metric_kind_hint" do
    it "spiega ogni categoria (it/en, non vuota)" do
      %i[it en].each do |loc|
        I18n.with_locale(loc) do
          Metrics::Group.kinds.each_key { |k| expect(helper.metric_kind_hint(k)).to be_present }
        end
      end
    end

    it "kind sconosciuto → stringa vuota (nessuna riga di spiegazione)" do
      expect(helper.metric_kind_hint("boh")).to eq("")
    end
  end

  describe "#perf_subtype_hint" do
    it "spiega ogni tipo di problema (it/en, non vuota)" do
      %i[it en].each do |loc|
        I18n.with_locale(loc) do
          Metrics::Group::PERFORMANCE_SUBTYPES.each { |s| expect(helper.perf_subtype_hint(s)).to be_present }
        end
      end
    end

    it "subtype sconosciuto → stringa vuota" do
      expect(helper.perf_subtype_hint("boh")).to eq("")
    end
  end

  describe "#metric_duration_color (confini 149/150/499/500)" do
    it { expect(helper.metric_duration_color(nil)).to eq("text-gray-400 dark:text-zinc-500") }
    it { expect(helper.metric_duration_color(149)).to eq("text-emerald-600 dark:text-emerald-400") }
    it { expect(helper.metric_duration_color(150)).to eq("text-amber-600 dark:text-amber-400") }
    it { expect(helper.metric_duration_color(499)).to eq("text-amber-600 dark:text-amber-400") }
    it { expect(helper.metric_duration_color(500)).to eq("text-red-600 dark:text-red-400") }

    # CYRA-341: il colore segue le soglie del progetto quando ci sono.
    it "con le soglie del progetto sposta i confini" do
      soglie = { fast: 20, slow: 60 }
      expect(helper.metric_duration_color(19, soglie)).to eq("text-emerald-600 dark:text-emerald-400")
      expect(helper.metric_duration_color(59, soglie)).to eq("text-amber-600 dark:text-amber-400")
      expect(helper.metric_duration_color(60, soglie)).to eq("text-red-600 dark:text-red-400")
    end
  end

  # CYRA-341 — scenario 2: «da che valore in su un numero diventa rosso» dev'essere scritto dove il
  # numero si legge, non solo nel codice.
  describe "#metric_threshold_hint" do
    it "dice le due soglie e dove si cambiano" do
      testo = I18n.with_locale(:it) { helper.metric_threshold_hint(fast: 20, slow: 60) }

      expect(testo).to include("20ms").and include("60ms")
      expect(testo).to include("impostazioni")
    end

    it "senza soglie ripiega su quelle di sistema (mai una riga senza spiegazione)" do
      testo = helper.metric_threshold_hint

      expect(testo).to include("#{Metrics::Group::FAST_MS}ms").and include("#{Metrics::Group::MEDIUM_MS}ms")
    end
  end

  describe "#metric_trend (variazione sul periodo precedente)" do
    it "peggioramento → freccia su, rosso (per una durata, più è peggio)" do
      trend = helper.metric_trend(current_ms: 810, previous_ms: 600, delta_pct: 35)

      expect(trend[:label]).to eq("▲ 35%")
      expect(trend[:color]).to eq(:rose)
    end

    it "miglioramento → freccia giù, verde" do
      trend = helper.metric_trend(current_ms: 300, previous_ms: 600, delta_pct: -50)

      expect(trend[:label]).to eq("▼ 50%")
      expect(trend[:color]).to eq(:emerald)
    end

    it "nessuna variazione → etichetta neutra" do
      trend = helper.metric_trend(current_ms: 600, previous_ms: 600, delta_pct: 0)

      expect(trend[:color]).to eq(:gray)
      expect(trend[:label]).to eq(I18n.t("member.metrics.trend_flat"))
    end

    it "senza confronto possibile non mostra niente (mai un delta inventato)" do
      expect(helper.metric_trend(current_ms: 900, previous_ms: nil, delta_pct: nil)).to be_nil
      expect(helper.metric_trend(nil)).to be_nil
    end
  end

  describe "#metric_duration_bars (grafico della durata nel tempo)" do
    let(:base) { Time.zone.local(2026, 6, 1, 9, 0, 0) }

    it "altezza ∝ p95, colore per soglia, tooltip con p50 e p95" do
      buckets = [ { status: :slow, count: 5, p50: 300, p95: 820, at: base } ]
      bar = helper.metric_duration_bars(buckets, 820, "30m").first

      expect(bar).to include(color_class: "bg-red-400", height: 100, time_label: "09:00–09:01")
      expect(bar[:value_line]).to eq("p50 300ms · p95 820ms")
    end

    it "blocco senza campioni → traccia grigia e «nessun dato»" do
      buckets = [ { status: :empty, count: 0, p50: nil, p95: nil, at: base } ]
      bar = helper.metric_duration_bars(buckets, 820, "30m").first

      expect(bar).to include(color_class: "bg-stone-200/80 dark:bg-zinc-700/80", height: 6)
      expect(bar[:value_line]).to eq(helper.t("member.metrics.bucket.no_data"))
    end

    it "le barre della durata non sono cliccabili (il drill-down resta sulle occorrenze)" do
      buckets = [ { status: :slow, count: 5, p50: 300, p95: 820, at: base } ]

      expect(helper.metric_duration_bars(buckets, 820, "30m")).to all(include(href: nil))
    end

    # CYRA-570 — trenta barrette identiche mentre il grafico gemello sopra dichiarava il vuoto.
    it "marca i blocchi senza campioni, così un periodo vuoto si può dichiarare" do
      buckets = [ { status: :slow, count: 5, p50: 300, p95: 820, at: base },
                  { status: :empty, count: 0, p50: nil, p95: nil, at: base + 60 } ]
      bars = helper.metric_duration_bars(buckets, 820, "30m")

      expect(bars.first[:empty]).to be(false)
      expect(bars.last[:empty]).to be(true)
    end
  end

  describe "#metric_bucket_class" do
    it { expect(helper.metric_bucket_class(:fast)).to eq("bg-emerald-300") }
    it { expect(helper.metric_bucket_class(:medium)).to eq("bg-amber-300") }
    it { expect(helper.metric_bucket_class(:slow)).to eq("bg-red-400") }
    it { expect(helper.metric_bucket_class(:empty)).to eq("bg-stone-200/80 dark:bg-zinc-700/80") }
    it { expect(helper.metric_bucket_class(:boh)).to eq("bg-stone-200/80 dark:bg-zinc-700/80") }
  end

  describe "#metric_bucket_title" do
    it "blocco pieno → 'avg · count'" do
      expect(helper.metric_bucket_title({ status: :slow, avg_ms: 1240, count: 5 })).to eq("1.2s · 5 occ")
    end
  end

  describe "#metric_bucket_height (∝ picco, floor 4)" do
    it { expect(helper.metric_bucket_height(0, 10)).to eq(0) }
    it { expect(helper.metric_bucket_height(5, 0)).to eq(0) }
    it { expect(helper.metric_bucket_height(5, 10)).to eq(50) }
    it { expect(helper.metric_bucket_height(10, 10)).to eq(100) }
    it "floor 4 per count piccolo non-zero" do
      expect(helper.metric_bucket_height(1, 100)).to eq(4)
    end
  end

  describe "#metric_chart_bars" do
    let(:base) { Time.zone.local(2026, 6, 1, 9, 0, 0) }

    it "blocco pieno → colore performance, altezza ∝ picco, tooltip con durata media" do
      buckets = [ { status: :slow, count: 5, avg_ms: 820, at: base } ]
      bar = helper.metric_chart_bars(buckets, 5, "30m").first
      expect(bar).to include(color_class: "bg-red-400", height: 100, time_label: "09:00–09:01")
      expect(bar[:value_line]).to eq("820ms · 5 occ")
    end

    it "blocco vuoto → traccia grigia stub 6% e 'nessun dato'" do
      buckets = [ { status: :empty, count: 0, avg_ms: nil, at: base } ]
      bar = helper.metric_chart_bars(buckets, 5, "30m").first
      expect(bar).to include(color_class: "bg-stone-200/80 dark:bg-zinc-700/80", height: 6)
      expect(bar[:value_line]).to eq(helper.t("member.metrics.bucket.no_data"))
    end

    # CYRA-570 — il flag che permette al grafico di dichiarare un periodo senza occorrenze.
    it "marca i blocchi senza occorrenze" do
      buckets = [ { status: :slow, count: 5, avg_ms: 820, at: base },
                  { status: :empty, count: 0, avg_ms: nil, at: base + 60 } ]
      bars = helper.metric_chart_bars(buckets, 5, "30m")

      expect(bars.first[:empty]).to be(false)
      expect(bars.last[:empty]).to be(true)
    end
  end

  # CYRA-46: drill-down dall'istogramma metriche (speculare agli errori).
  describe "#metric_chart_bars drill-down (CYRA-46)" do
    let(:base) { Time.zone.local(2026, 6, 1, 9, 0, 0) }
    let(:buckets) do
      [ { status: :slow, count: 5, avg_ms: 820, at: base },
        { status: :empty, count: 0, avg_ms: nil, at: base + 60 } ]
    end
    let(:href) { ->(from, to) { "/m?from=#{from.to_i}&to=#{to.to_i}" } }

    it("senza bucket_href nessuna barra è cliccabile né attiva (retrocompat)") do
      expect(helper.metric_chart_bars(buckets, 5, "30m")).to all(include(href: nil, active: false))
    end

    it("con bucket_href i blocchi NON vuoti diventano cliccabili (from/to del blocco)") do
      bars = helper.metric_chart_bars(buckets, 5, "30m", bucket_href: href)
      expect(bars.first[:href]).to eq("/m?from=#{base.to_i}&to=#{(base + 60).to_i}")
      expect(bars.last[:href]).to be_nil
    end

    it("marca active il blocco che rappresenta la finestra filtro, robusto allo shift dei bucket (CYRA-46 review)") do
      shifted = [ { status: :slow, count: 5, avg_ms: 820, at: base + 3 },
                  { status: :empty, count: 0, avg_ms: nil, at: base + 63 } ]
      bars = helper.metric_chart_bars(shifted, 5, "30m", active_from: base, active_to: base + 60)
      expect(bars.first[:active]).to be(true)   # midpoint base+30 ∈ [base+3, base+63)
      expect(bars.last[:active]).to be(false)
    end
  end

  # I tipi che manda la gemma per i lavori in background comparivano col nome grezzo («slow_job»).
  describe "#perf_subtype_label dei lavori in background" do
    it { expect(I18n.with_locale(:it) { helper.perf_subtype_label("job_queue_latency") }).to eq("Attesa in coda") }
    it { expect(I18n.with_locale(:it) { helper.perf_subtype_label("slow_job") }).to eq("Lavoro lento") }
  end

  describe "#metric_duration_label" do
    it { expect(helper.metric_duration_label(nil)).to eq("—") }
    it { expect(helper.metric_duration_label(820.4)).to eq("820ms") }
    # Da un secondo in su si scala come il tempo totale: «974203ms» non si legge, «16.2min» sì.
    it { expect(helper.metric_duration_label(1240.4)).to eq("1.2s") }
    it { expect(helper.metric_duration_label(974_203)).to eq("16.2min") }
  end

  # CYRA-339: il tempo totale speso (durata totale = media × occorrenze) può valere centinaia di
  # milioni di ms → va scalato a s/min/h/g con una sola unità dominante e senza ".0" superfluo.
  describe "#metric_total_duration_label" do
    it { expect(helper.metric_total_duration_label(nil)).to eq("—") }
    it { expect(helper.metric_total_duration_label(810)).to eq("810ms") }
    it { expect(helper.metric_total_duration_label(999)).to eq("999ms") }
    it { expect(helper.metric_total_duration_label(5_200)).to eq("5.2s") }
    it { expect(helper.metric_total_duration_label(90_000)).to eq("1.5min") }
    it { expect(helper.metric_total_duration_label(9_000_000)).to eq("2.5h") }

    it "localizza l'unità giorni (it «g», en «d»)" do
      expect(I18n.with_locale(:it) { helper.metric_total_duration_label(172_800_000) }).to eq("2g")
      expect(I18n.with_locale(:en) { helper.metric_total_duration_label(172_800_000) }).to eq("2d")
    end
  end

  describe "#metric_time_ago" do
    it { expect(helper.metric_time_ago(nil)).to eq("—") }
  end

  describe "#metric_percentiles_label (CYRA-146)" do
    let(:pct) { { 50 => 20.0, 95 => 29.0, 99 => 5000.0 } }

    it "formatta tutte le sigle con la durata" do
      expect(helper.metric_percentiles_label(pct)).to eq("p50 20ms · p95 29ms · p99 5s")
    end

    it "seleziona solo le sigle passate (riassunto casi peggiori)" do
      expect(helper.metric_percentiles_label(pct, [ 95, 99 ])).to eq("p95 29ms · p99 5s")
    end

    it "tutti nil (nessun campione) → —" do
      expect(helper.metric_percentiles_label({ 50 => nil, 95 => nil, 99 => nil })).to eq("—")
    end

    it "hash vuoto o nil → —" do
      expect(helper.metric_percentiles_label({})).to eq("—")
      expect(helper.metric_percentiles_label(nil)).to eq("—")
    end
  end

  describe "dettaglio occorrenza (payload)" do
    def occ(payload) = Struct.new(:payload).new(payload)

    it "occurrence_payload nil → {}" do
      expect(helper.occurrence_payload(nil)).to eq({})
    end

    it "occurrence_bindings legge i bindings (slow_query)" do
      expect(helper.occurrence_bindings(occ("bindings" => [ { "name" => "a", "value" => "1" } ])))
        .to eq([ { "name" => "a", "value" => "1" } ])
    end

    it "occurrence_bindings ricade su arguments (slow_method)" do
      expect(helper.occurrence_bindings(occ("arguments" => [ { "name" => "x", "value" => "2" } ])))
        .to eq([ { "name" => "x", "value" => "2" } ])
    end

    it "occurrence_bindings vuoto senza cattura" do
      expect(helper.occurrence_bindings(occ("sql" => "SELECT 1"))).to eq([])
    end

    it "occurrence_source preferisce source" do
      expect(helper.occurrence_source(occ("source" => "app/x.rb:9", "file" => "y.rb"))).to eq("app/x.rb:9")
    end

    it "occurrence_source compone file:lineno" do
      expect(helper.occurrence_source(occ("file" => "app/y.rb", "lineno" => 42))).to eq("app/y.rb:42")
    end

    it "occurrence_source nil senza file" do
      expect(helper.occurrence_source(occ("sql" => "SELECT 1"))).to be_nil
    end

    it "occurrence_db_system legge db_system" do
      expect(helper.occurrence_db_system(occ("db_system" => "postgresql"))).to eq("postgresql")
    end

    describe "occurrence_sdk (etichetta 'nome versione', mai l'Hash grezzo — CYRA-20)" do
      it "Hash {name, version} → 'nome versione' leggibile" do
        expect(helper.occurrence_sdk(occ("sdk" => { "name" => "closeyourit-ruby", "version" => "0.4.0" })))
          .to eq("closeyourit-ruby 0.4.0")
      end

      it "Hash con solo name → name" do
        expect(helper.occurrence_sdk(occ("sdk" => { "name" => "closeyourit-ruby" }))).to eq("closeyourit-ruby")
      end

      it "Hash con solo version → version" do
        expect(helper.occurrence_sdk(occ("sdk" => { "version" => "0.4.0" }))).to eq("0.4.0")
      end

      it "Hash vuoto → nil (la vista mostra il fallback)" do
        expect(helper.occurrence_sdk(occ("sdk" => {}))).to be_nil
      end

      it "stringa già formattata → invariata (retrocompat)" do
        expect(helper.occurrence_sdk(occ("sdk" => "closeyourit-ruby 0.1.0"))).to eq("closeyourit-ruby 0.1.0")
      end

      it "sdk assente → nil" do
        expect(helper.occurrence_sdk(occ("sql" => "SELECT 1"))).to be_nil
      end
    end
  end
end
