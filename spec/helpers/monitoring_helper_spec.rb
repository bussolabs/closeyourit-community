# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonitoringHelper, type: :helper do
  describe "#error_level_color" do
    it { expect(helper.error_level_color("debug")).to eq(:gray) }
    it { expect(helper.error_level_color("info")).to eq(:sky) }
    it { expect(helper.error_level_color("warning")).to eq(:amber) }
    it { expect(helper.error_level_color("error")).to eq(:orange) }
    it { expect(helper.error_level_color("fatal")).to eq(:red) }
    it("valore ignoto → gray") { expect(helper.error_level_color("boh")).to eq(:gray) }
  end

  describe "#error_status_color" do
    it { expect(helper.error_status_color("unresolved")).to eq(:amber) }
    it { expect(helper.error_status_color("resolved")).to eq(:emerald) }
    it { expect(helper.error_status_color("ignored")).to eq(:gray) }
    it("valore ignoto → gray") { expect(helper.error_status_color("boh")).to eq(:gray) }
  end

  describe "#error_time_ago" do
    it("blank → —") { expect(helper.error_time_ago(nil)).to eq("—") }
    it("presente → label tradotta, non —") do
      expect(helper.error_time_ago(2.hours.ago)).not_to eq("—")
    end
  end

  describe "#error_bucket_height (count/max ai confini)" do
    it("count zero → 0") { expect(helper.error_bucket_height(0, 100)).to eq(0) }
    it("max zero → 0")   { expect(helper.error_bucket_height(5, 0)).to eq(0) }
    it("non-zero → minimo visibile 4") { expect(helper.error_bucket_height(1, 100)).to eq(4) }
    it("proporzionale al massimo")     { expect(helper.error_bucket_height(50, 100)).to eq(50) }
  end

  describe "#chart_gridlines" do
    it("max < 2 → nessuna riga") do
      expect(helper.chart_gridlines(1)).to eq([])
      expect(helper.chart_gridlines(0)).to eq([])
    end

    it("include sempre la riga di picco (100%)") do
      lines = helper.chart_gridlines(10)
      expect(lines.last).to eq(value: 10, pct: 100.0)
    end

    it("picco tondo → passo tondo (max 10 → 5, 10)") do
      expect(helper.chart_gridlines(10).map { |g| g[:value] }).to eq([ 5, 10 ])
    end

    it("aggiunge la riga di picco quando non cade sul passo (max 47)") do
      values = helper.chart_gridlines(47).map { |g| g[:value] }
      expect(values).to eq([ 20, 40, 47 ])
      expect(values.last).to eq(47)
    end
  end

  describe "#chart_nice_step (soglie 1/2/5/10)" do
    it("norm ≤ 1 → 1")  { expect(helper.chart_nice_step(3)).to eq(1) }
    it("norm ≤ 2 → 2")  { expect(helper.chart_nice_step(47)).to eq(20) }
    it("norm ≤ 5 → 5")  { expect(helper.chart_nice_step(10)).to eq(5) }
    it("norm > 5 → 10") { expect(helper.chart_nice_step(2)).to eq(1) }
  end

  describe "#chart_time_format" do
    it("range breve → :chart_time") { expect(helper.chart_time_format("24h")).to eq(:chart_time) }
    it("range lungo → :chart_day")  { expect(helper.chart_time_format("7d")).to eq(:chart_day) }
    # CYRA-500: sull'arco di un anno la tacca porta anche l'anno, altrimenti un periodo a cavallo del
    # capodanno scrive «10/08 … 02/08» senza dire in quale dei due anni si trova ogni tacca.
    it("1y (bucket settimanali analytics) → :chart_year") { expect(helper.chart_time_format("1y")).to eq(:chart_year) }
  end

  describe "#chart_bucket_window" do
    it("at blank → stringa vuota") { expect(helper.chart_bucket_window(nil, 60, "30m")).to eq("") }
    it("inizio–fine col formato del range") do
      at = Time.zone.local(2026, 6, 1, 9, 0, 0)
      expect(helper.chart_bucket_window(at, 60, "30m")).to eq("09:00–09:01")
    end
  end

  describe "#chart_xticks" do
    it("meno di 2 bucket → nessun tick") { expect(helper.chart_xticks([ { at: Time.current } ], "30m")).to eq([]) }

    it("≈4 tick equispaziati con label formattata e pct 0..100") do
      base = Time.zone.local(2026, 6, 1, 9, 0, 0)
      buckets = Array.new(30) { |i| { at: base + (i * 60) } }
      ticks = helper.chart_xticks(buckets, "30m")
      expect(ticks.first).to include(label: "09:00", pct: 0.0)
      expect(ticks.last[:pct]).to eq(100.0)
      expect(ticks.size).to be <= 4
    end
  end

  describe "#error_chart_bars" do
    it("mappa i bucket in view-model (indigo/pieno, grigio/vuoto) con finestra e conteggio") do
      base = Time.zone.local(2026, 6, 1, 9, 0, 0)
      buckets = [ { count: 3, at: base }, { count: 0, at: base + 60 } ]
      bars = helper.error_chart_bars(buckets, 3, "30m")

      expect(bars.first).to include(color_class: "bg-indigo-500", height: 100, time_label: "09:00–09:01")
      expect(bars.first[:value_line]).to eq("3 occurrences")
      expect(bars.last).to include(color_class: "bg-stone-200 dark:bg-zinc-700", height: 6)
      expect(bars.last[:value_line]).to eq("no occurrences")
    end

    # CYRA-570 — il componente deve poter riconoscere un periodo in cui non è stato misurato nulla:
    # senza questo flag disegna barrette minime che si leggono come valori piccoli.
    it "marca i blocchi senza occorrenze, così un periodo vuoto si può dichiarare" do
      base = Time.zone.local(2026, 6, 1, 9, 0, 0)
      bars = helper.error_chart_bars([ { count: 3, at: base }, { count: 0, at: base + 60 } ], 3, "30m")

      expect(bars.first[:empty]).to be(false)
      expect(bars.last[:empty]).to be(true)
    end
  end

  # CYRA-46: drill-down dall'istogramma. Le barre non-vuote diventano cliccabili (from/to del blocco)
  # e il blocco che contiene la finestra filtro attiva si evidenzia.
  describe "#error_chart_bars drill-down (CYRA-46)" do
    let(:base) { Time.zone.local(2026, 6, 1, 9, 0, 0) }
    let(:buckets) { [ { count: 3, at: base }, { count: 0, at: base + 60 } ] }
    let(:href) { ->(from, to) { "/g?from=#{from.to_i}&to=#{to.to_i}" } }

    it("senza bucket_href nessuna barra è cliccabile né attiva (retrocompat)") do
      expect(helper.error_chart_bars(buckets, 3, "30m")).to all(include(href: nil, active: false))
    end

    it("con bucket_href i blocchi NON vuoti diventano cliccabili (from=inizio, to=inizio+durata)") do
      bars = helper.error_chart_bars(buckets, 3, "30m", bucket_href: href)
      expect(bars.first[:href]).to eq("/g?from=#{base.to_i}&to=#{(base + 60).to_i}")
      expect(bars.last[:href]).to be_nil
    end

    it("marca active il blocco che rappresenta la finestra filtro [from, to)") do
      bars = helper.error_chart_bars(buckets, 3, "30m", active_from: base, active_to: base + 60)
      expect(bars.first[:active]).to be(true)
      expect(bars.last[:active]).to be(false)
    end

    # Difetto segnalato in review: i bucket sono ricalcolati rispetto a Time.current a ogni request e
    # "scivolano" rispetto al from dell'URL (fisso e troncato al secondo). Con "at <= from" il primo
    # blocco (ora a base+3) non verrebbe evidenziato; col punto medio della finestra sì.
    it("evidenzia il blocco corretto anche se i bucket sono scivolati (shift + troncatura, CYRA-46 review)") do
      shifted = [ { count: 3, at: base + 3 }, { count: 1, at: base + 63 } ]
      bars = helper.error_chart_bars(shifted, 3, "30m", active_from: base, active_to: base + 60)
      expect(bars.first[:active]).to be(true)  # midpoint base+30 ∈ [base+3, base+63)
      expect(bars.last[:active]).to be(false)
    end

    it("senza active_to (finestra incompleta) nessun blocco è attivo") do
      expect(helper.error_chart_bars(buckets, 3, "30m", active_from: base)).to all(include(active: false))
    end

    it("espone aria_label leggibile (finestra + conteggio) per il link") do
      bars = helper.error_chart_bars(buckets, 3, "30m", bucket_href: href)
      expect(bars.first[:aria_label]).to include("09:00–09:01").and include("occurrence")
    end
  end

  # CYRA-379: un valore oscurato dagli scrubber (backend o SDK) arriva come "[FILTERED]". Nel
  # rendering va distinto da un dato assente e mostrato con una dicitura comprensibile, non con
  # la sigla tecnica. Il riconoscimento è bracket/case-insensitive (parità con
  # Projects::Source::PLACEHOLDER_CODES: "[FILTERED]", "FILTERED", "[Redacted]").
  describe "#error_scrubbed? (CYRA-379)" do
    it("riconosce il letterale [FILTERED]") { expect(helper.error_scrubbed?("[FILTERED]")).to be(true) }

    it("è bracket/case-insensitive") do
      expect(helper.error_scrubbed?("filtered")).to be(true)
      expect(helper.error_scrubbed?("[Redacted]")).to be(true)
      expect(helper.error_scrubbed?("REDACTED")).to be(true)
    end

    it("un valore reale (path, nome) → false") do
      expect(helper.error_scrubbed?("/app/app/views/events/show.html.erb")).to be(false)
      expect(helper.error_scrubbed?("web-1")).to be(false)
    end

    it("blank/nil → false (dato assente, non oscurato)") do
      expect(helper.error_scrubbed?("")).to be(false)
      expect(helper.error_scrubbed?(nil)).to be(false)
    end
  end

  describe "#error_value (CYRA-379)" do
    it("valore oscurato → dicitura leggibile, mai la sigla tecnica") do
      html = helper.error_value("[FILTERED]")
      expect(html).to include(I18n.t("member.monitoring.value_scrubbed"))
      expect(html).to include('data-test="scrubbed-value"')
      expect(html).not_to include("[FILTERED]")
    end

    it("valore reale → invariato") { expect(helper.error_value("web-1")).to eq("web-1") }
  end

  describe "#error_culprit (CYRA-379)" do
    it("sostituisce SOLO il token oscurato, conservando il metodo leggibile") do
      html = helper.error_culprit("[FILTERED] in ActiveJob::Core::ClassMethods#deserialize")
      expect(html).to include("ActiveJob::Core::ClassMethods#deserialize")
      expect(html).to include(I18n.t("member.monitoring.value_scrubbed"))
      expect(html).not_to include("[FILTERED]")
    end

    it("culprit interamente leggibile → invariato") do
      expect(helper.error_culprit("App::Widget#render")).to eq("App::Widget#render")
    end

    it("blank → nil") { expect(helper.error_culprit(nil)).to be_nil }
  end

  describe "#error_culprit_text (testo piano per gli attributi, CYRA-379)" do
    it("sostituisce il token con la label leggibile") do
      expect(helper.error_culprit_text("[FILTERED] in #deserialize"))
        .to eq("#{I18n.t('member.monitoring.value_scrubbed')} in #deserialize")
    end

    it("placeholder intero senza parentesi → label (coerenza con error_value)") do
      expect(helper.error_culprit_text("FILTERED")).to eq(I18n.t("member.monitoring.value_scrubbed"))
    end

    it("culprit leggibile → invariato") { expect(helper.error_culprit_text("App::Widget#render")).to eq("App::Widget#render") }
  end

  describe "#error_value_deep (valori compositi annidati, CYRA-379)" do
    it("stringa → come error_value") do
      expect(helper.error_value_deep("[FILTERED]")).to include(I18n.t("member.monitoring.value_scrubbed"))
      expect(helper.error_value_deep("web-1")).to eq("web-1")
    end

    it("hash/array con placeholder annidato → JSON senza la sigla tecnica") do
      json = helper.error_value_deep("user" => { "password" => "[FILTERED]" }, "ok" => "x")
      expect(json).to include(I18n.t("member.monitoring.value_scrubbed"))
      expect(json).not_to include("[FILTERED]")
      expect(json).to include("x")
    end
  end

  describe "#any_scrubbed? / #frames_scrubbed? (avviso una volta per sezione, CYRA-379)" do
    it("any_scrubbed? vero se un valore è oscurato, intero o embedded") do
      expect(helper.any_scrubbed?([ "web-1", "[FILTERED]" ])).to be(true)
      expect(helper.any_scrubbed?([ "[FILTERED] 1.0" ])).to be(true)
      expect(helper.any_scrubbed?([ "web-1", "ruby 4.0.5" ])).to be(false)
    end

    it("any_scrubbed? vero anche per un placeholder annidato in hash/array") do
      expect(helper.any_scrubbed?([ { "a" => { "b" => "[FILTERED]" } } ])).to be(true)
      expect(helper.any_scrubbed?([ { "a" => "ok" } ])).to be(false)
    end

    it("frames_scrubbed? vero se filename/module/function di un frame è oscurato") do
      expect(helper.frames_scrubbed?([ { "filename" => "[FILTERED]", "function" => "call" } ])).to be(true)
      expect(helper.frames_scrubbed?([ { "filename" => "app/x.rb", "function" => "call" } ])).to be(false)
      expect(helper.frames_scrubbed?([ "non-hash", nil ])).to be(false)
    end

    # Il payload di un errore è jsonb: liste e dizionari annidati devono attraversare lo scrubbing
    # come le stringhe, e un numero deve restare un numero.
    it("error_value lascia stare ciò che non è testo e sostituisce il token dentro una frase") do
      expect(helper.error_value(42)).to eq(42)
      expect(helper.error_value("tutto bene")).to eq("tutto bene")
      expect(helper.error_value("token=[FILTERED] scaduto")).to include("token=")
    end

    it("error_value_deep e error_deep_text scendono dentro liste e dizionari") do
      expect(helper.error_value_deep(7)).to eq(7)
      expect(helper.error_value_deep("password=[REDACTED]")).to be_a(String)
      expect(helper.error_value_deep([ "a", "[FILTERED]" ])).to include("a")
      expect(helper.error_deep_text({ "a" => [ "[FILTERED]", 3 ] })).to eq({ "a" => [ I18n.t("member.monitoring.value_scrubbed"), 3 ] })
    end

    it("deep_scrubbed? riconosce l'oscuramento a qualsiasi profondità") do
      expect(helper.deep_scrubbed?({ "a" => { "b" => "[FILTERED]" } })).to be(true)
      expect(helper.deep_scrubbed?([ "x", { "y" => "ok" } ])).to be(false)
      expect(helper.deep_scrubbed?(3)).to be(false)
    end

    it("error_culprit_text tace sul vuoto e traduce il placeholder intero") do
      expect(helper.error_culprit_text("")).to eq("")
      expect(helper.error_culprit_text("[FILTERED]")).to eq(I18n.t("member.monitoring.value_scrubbed"))
      expect(helper.error_culprit_text("App::Job#call")).to eq("App::Job#call")
    end
  end
  # CYRA-354 — il conteggio filtrato col totale accanto, e il colore dei blocchi del grafico. Sono
  # tre righe di presentazione, ma sbagliarle significa dire un numero falso o accendere di rosso un
  # periodo tranquillo.
  describe "#log_count_label" do
    it "col filtro attivo dice quanti su quanti" do
      atteso = I18n.t("member.monitoring.logs.count_of",
                      filtered: helper.number_with_delimiter(36), total: helper.number_with_delimiter(55_148))

      expect(helper.log_count_label(36, 55_148)).to eq(atteso)
    end

    it "senza filtro è un numero solo" do
      expect(helper.log_count_label(12, 12)).to eq("12")
    end

    it "senza conteggio filtrato ripiega sul totale" do
      expect(helper.log_count_label(nil, 12)).to eq("12")
    end
  end

  # D18 — "36 of 55,148" says what the two numbers are on hover; with no filter there is one number
  # and nothing to explain.
  describe "#log_count_title" do
    it "explains the two numbers when a filter narrows the list" do
      expect(helper.log_count_title(36, 55_148)).to eq(I18n.t("member.monitoring.logs.count_of_title"))
    end

    it "says nothing when the numbers are the same" do
      expect(helper.log_count_title(12, 12)).to be_nil
      expect(helper.log_count_title(nil, 12)).to be_nil
    end
  end

  describe "#log_volume_bar_class" do
    Bucket = Struct.new(:alarming) unless defined?(Bucket)

    it "un blocco vuoto resta spento" do
      expect(helper.log_volume_bar_class(Bucket.new(0), true)).to eq("bg-stone-100 dark:bg-zinc-800")
    end

    it "un blocco con voci allarmanti è rosso" do
      expect(helper.log_volume_bar_class(Bucket.new(3), false)).to eq("bg-rose-400")
    end

    it "un blocco tranquillo non allarma" do
      expect(helper.log_volume_bar_class(Bucket.new(0), false)).to eq("bg-indigo-300")
    end
  end

  # CYRA-570 — quarantotto blocchi a zero disegnavano una striscia di barrette identiche che si
  # legge come «pochissimi messaggi». Il flag dice al componente che quel blocco non ha niente.
  describe "#log_volume_bars" do
    let(:base) { Time.zone.local(2026, 6, 1, 9, 0, 0) }

    def volume_bucket(count:, alarming: 0, from: base)
      Logs::VolumeBuckets::Bucket.new(from: from, to: from + 60, count: count, alarming: alarming)
    end

    it "marca i blocchi senza messaggi e lascia intatti quelli pieni" do
      bars = helper.log_volume_bars([ volume_bucket(count: 4), volume_bucket(count: 0, from: base + 60) ],
                                    4, href_for: ->(bucket) { "/l?from=#{bucket.from.to_i}" })

      expect(bars.first).to include(empty: false, height: 100)
      expect(bars.last).to include(empty: true, href: nil)
    end
  end

  # CYRA-577 — il titolo di un registro. Il messaggio intero di un'eccezione Rails sono quasi tremila
  # caratteri col backtrace dentro: come titolo riempiva più di una schermata da solo.
  describe "#log_entry_headline" do
    def entry(message) = build(:log_entry, message: message)

    it "prende la sola prima riga, non tutto il messaggio" do
      messaggio = "ActiveRecord::RecordNotFound (Couldn't find User)\n  app/models/user.rb:12:in `find'\n  app/controllers/users_controller.rb:8"

      expect(helper.log_entry_headline(entry(messaggio)))
        .to eq("ActiveRecord::RecordNotFound (Couldn't find User)")
    end

    it "taglia una prima riga lunghissima" do
      titolo = helper.log_entry_headline(entry("x" * 3_000))

      expect(titolo.length).to be <= MonitoringHelper::LOG_HEADLINE_MAX
      expect(titolo).to end_with("…")
    end

    it "toglie il codice della richiesta dalla testa, che si legge già nel riquadro della richiesta" do
      messaggio = "[e146fed6-1a2b-4c3d-8e4f-556677889900] ActiveRecord::RecordNotFound (Couldn't find User)"

      expect(helper.log_entry_headline(entry(messaggio)))
        .to eq("ActiveRecord::RecordNotFound (Couldn't find User)")
    end

    it "salta la riga vuota che Rails mette prima del messaggio d'eccezione" do
      messaggio = "  \n[e146fed6-1a2b-4c3d-8e4f-556677889900] NoMethodError (undefined method)\n  riga di backtrace"

      expect(helper.log_entry_headline(entry(messaggio))).to eq("NoMethodError (undefined method)")
    end

    it "un tag che non è un codice di richiesta resta al suo posto" do
      expect(helper.log_entry_headline(entry("[CLI] avvio del comando"))).to eq("[CLI] avvio del comando")
    end

    it "col solo codice di richiesta tiene la riga com'è, invece di restare senza titolo" do
      expect(helper.log_entry_headline(entry("[e146fed6-1a2b-4c3d-8e4f-556677889900]")))
        .to eq("[e146fed6-1a2b-4c3d-8e4f-556677889900]")
    end

    it "il limite si può stringere (briciola di pane, nome della scheda)" do
      titolo = helper.log_entry_headline(entry("ActiveRecord::RecordNotFound (Couldn't find User)"), limit: 20)

      expect(titolo.length).to be <= 20
    end
  end
end
