# frozen_string_literal: true

require "rails_helper"

RSpec.describe ServersHelper, type: :helper do
  describe "soglie cromatiche percentuali (<50 verde / 50-79 giallo / ≥80 rosso)" do
    it "server_pct_color: basso verde, 59 giallo, alto rosso, nil grigio" do
      expect(helper.server_pct_color(4)).to eq("text-emerald-600 dark:text-emerald-400")
      expect(helper.server_pct_color(49.9)).to eq("text-emerald-600 dark:text-emerald-400")
      expect(helper.server_pct_color(50)).to eq("text-amber-600 dark:text-amber-400")
      expect(helper.server_pct_color(59)).to eq("text-amber-600 dark:text-amber-400")
      expect(helper.server_pct_color(79.9)).to eq("text-amber-600 dark:text-amber-400")
      expect(helper.server_pct_color(80)).to eq("text-red-600 dark:text-red-400")
      expect(helper.server_pct_color(nil)).to eq("text-gray-400 dark:text-zinc-500")
    end

    it "server_bar_class: stesse soglie (barra fleet)" do
      expect(helper.server_bar_class(10)).to eq("bg-emerald-400")
      expect(helper.server_bar_class(59)).to eq("bg-amber-300")
      expect(helper.server_bar_class(95)).to eq("bg-red-400")
      expect(helper.server_bar_class(nil)).to eq("bg-stone-200 dark:bg-zinc-700")
    end

    it "server_bucket_class: stesse soglie (istogramma show)" do
      expect(helper.server_bucket_class(20)).to eq("bg-emerald-400")
      expect(helper.server_bucket_class(60)).to eq("bg-amber-300")
      expect(helper.server_bucket_class(88)).to eq("bg-red-400")
      expect(helper.server_bucket_class(nil)).to eq("bg-stone-200/80 dark:bg-zinc-700/80")
    end
  end

  describe "#server_chart_bars (view-model per Ui::HistogramComponent)" do
    let(:at) { Time.zone.local(2026, 7, 2, 12, 0, 0) }

    it "mappa una metrica percentuale a height ∝ valore, colore a soglia, finestra oraria e riga valore" do
      buckets = [ { cpu: 20.0, temp: 45.0, at: at, count: 3 }, { cpu: 88.0, temp: 45.0, at: at + 60, count: 5 } ]

      bars = helper.server_chart_bars(buckets, :cpu, "30m")

      expect(bars.length).to eq(2)
      expect(bars.first).to include(height: 20, color_class: "bg-emerald-400", value_line: "20%", unsampled: false)
      expect(bars.first[:time_label]).to be_present
      expect(bars.last).to include(height: 88, color_class: "bg-red-400", value_line: "88%", unsampled: false)
    end

    it "temp: altezza sul fondo scala del periodo, colore con soglie in °C e riga valore in gradi" do
      buckets = [ { temp: 30.0, at: at, count: 1 }, { temp: 60.0, at: at + 60, count: 1 } ]

      bars = helper.server_chart_bars(buckets, :temp, "30m")

      # picco 60° → fondo scala 60° → 30° sta a metà. Col vecchio cap 0-100 sarebbe stata alta 30.
      expect(bars.first).to include(height: 50, color_class: "bg-emerald-300", value_line: "30°")
      expect(bars.last).to include(height: 100, color_class: "bg-amber-300", value_line: "60°")
    end

    it "temp: un picco oltre i 100° non viene più tagliato via" do
      buckets = [ { temp: 60.0, at: at, count: 1 }, { temp: 120.0, at: at + 60, count: 1 } ]

      bars = helper.server_chart_bars(buckets, :temp, "30m")

      # Col cap a 100 entrambe le barre erano a 100 e il picco spariva: ora si vede che è il doppio.
      expect(bars.first[:height]).to eq(50)
      expect(bars.last[:height]).to eq(100)
    end

    it "mem/disk con il totale noto: la riga valore porta l'assoluto prima della percentuale" do
      buckets = [ { mem: 50.0, at: at, count: 3 } ]

      bars = helper.server_chart_bars(buckets, :mem, "30m", total_bytes: 32 * 1_073_741_824)

      expect(bars.first[:value_line]).to eq("16 GB · 50%")
    end

    it "mem/disk: i GB misurati nel blocco vincono sul ricalcolo dalla percentuale" do
      # Macchina passata da 16 a 32 GB: il blocco vecchio deve continuare a dire 8 GB, non 16.
      buckets = [ { mem: 50.0, mem_gb: 8.0, at: at, count: 3 } ]

      bars = helper.server_chart_bars(buckets, :mem, "30m", total_bytes: 32 * 1_073_741_824)

      expect(bars.first[:value_line]).to eq("8 GB · 50%")
    end

    it "blocco senza campioni (count 0): unsampled true, stub height 6 e riga 'nessun dato'" do
      bars = helper.server_chart_bars([ { cpu: nil, at: at, count: 0 } ], :cpu, "30m")

      expect(bars.first).to include(height: 6, color_class: "bg-stone-200/80 dark:bg-zinc-700/80", unsampled: true,
                                    value_line: I18n.t("member.servers.show.no_data"))
    end

    it "distingue un valore ZERO misurato (count > 0) da un blocco non misurato" do
      bars = helper.server_chart_bars([ { cpu: 0.0, at: at, count: 2 } ], :cpu, "30m")

      # cpu misurata a 0 → NON è unsampled: barra colorata minima, non fascia tratteggiata.
      expect(bars.first).to include(unsampled: false, color_class: "bg-emerald-400")
      expect(bars.first[:value_line]).to eq("0%")
    end
  end

  describe "#server_hires_since (inizio delle misure ad alta risoluzione)" do
    let(:at) { Time.zone.local(2026, 7, 2, 12, 0, 0) }

    it "ritorna l'istante del primo blocco con campioni, se preceduto da blocchi vuoti" do
      buckets = [ { count: 0, at: at }, { count: 0, at: at + 60 }, { count: 4, at: at + 120 } ]

      expect(helper.server_hires_since(buckets)).to eq(at + 120)
    end

    it "nil se il primo blocco è già pieno (nessun tratto iniziale da spiegare)" do
      buckets = [ { count: 2, at: at }, { count: 0, at: at + 60 } ]

      expect(helper.server_hires_since(buckets)).to be_nil
    end

    it "nil se nessun blocco ha campioni" do
      buckets = [ { count: 0, at: at }, { count: 0, at: at + 60 } ]

      expect(helper.server_hires_since(buckets)).to be_nil
    end

    it "nil su collezione vuota" do
      expect(helper.server_hires_since([])).to be_nil
    end
  end

  describe "#server_size_chart_bars (crescita di un database)" do
    let(:at) { Time.zone.local(2026, 7, 2, 12, 0, 0) }

    it "scala l'altezza sul picco del periodo e scrive la dimensione umana" do
      buckets = [ { size_bytes: 500, at: at }, { size_bytes: 1000, at: at + 60 } ]

      bars = helper.server_size_chart_bars(buckets, 1000, "30m")

      expect(bars.first).to include(height: 50, color_class: "bg-indigo-400")
      expect(bars.last[:height]).to eq(100)
      expect(bars.last[:value_line]).to eq(helper.server_bytes_text(1000))
    end

    it "blocco senza campioni: stub 6, traccia grigia, riga 'nessun dato'" do
      bars = helper.server_size_chart_bars([ { size_bytes: nil, at: at } ], 1000, "30m")

      expect(bars.first).to include(height: 6, color_class: "bg-stone-200/80 dark:bg-zinc-700/80", empty: true,
                                    value_line: I18n.t("member.servers.show.no_data"))
    end

    # CYRA-570 — il blocco misurato non è vuoto nemmeno quando la dimensione è zero: è un dato.
    it "un blocco misurato non è marcato vuoto" do
      bars = helper.server_size_chart_bars([ { size_bytes: 0, at: at } ], 1000, "30m")

      expect(bars.first[:empty]).to be(false)
    end

    it "picco a zero non fa dividere per zero" do
      bars = helper.server_size_chart_bars([ { size_bytes: 0, at: at } ], 0, "30m")

      expect(bars.first[:height]).to eq(6)
    end
  end

  describe "scala dei grafici di sistema (CYRA-472)" do
    it "server_pct_gridlines: fondo scala dichiarato 0 → 100%, uguale per ogni server" do
      expect(helper.server_pct_gridlines).to eq([
        { value: "0", pct: 0.0 }, { value: "50%", pct: 50.0 }, { value: "100%", pct: 100.0 }
      ])
    end

    it "server_temp_gridlines: gradini tondi da 20° fino al fondo scala, con lo zero alla base" do
      lines = helper.server_temp_gridlines([ { temp: 58.2 }, { temp: 41.0 } ])

      # picco 59 → fondo scala 60: righe tonde 0/20/40/60, non "50°" e "59°" appiccicate in cima.
      expect(lines.map { |l| l[:value] }).to eq([ "0", "20°", "40°", "60°" ])
      expect(lines.first[:pct]).to eq(0.0)
      expect(lines.last[:pct]).to eq(100.0)
    end

    it "server_temp_gridlines: oltre gli 80° allarga il passo invece di infittire le righe" do
      lines = helper.server_temp_gridlines([ { temp: 105.0 } ])

      expect(lines.map { |l| l[:value] }).to eq([ "0", "30°", "60°", "90°", "120°" ])
    end

    it "server_temp_gridlines: senza sensori nessun asse inventato" do
      expect(helper.server_temp_gridlines([ { temp: nil }, { temp: nil } ])).to eq([])
      expect(helper.server_temp_gridlines([])).to eq([])
    end

    it "server_temp_scale_max: multiplo di 20 sopra il picco, mai sotto i 40°" do
      expect(helper.server_temp_scale_max(59)).to eq(60)
      expect(helper.server_temp_scale_max(61)).to eq(80)
      expect(helper.server_temp_scale_max(40)).to eq(40)
      expect(helper.server_temp_scale_max(3)).to eq(40)
      expect(helper.server_temp_scale_max(nil)).to be_nil
    end

    it "server_temp_scale_max: la scala non balla a ogni refresh se il picco oscilla poco" do
      # La pagina si ridisegna a ogni push dell'agent: 52°→55°→58° devono dare lo stesso asse.
      expect([ 52, 55, 58 ].map { |peak| helper.server_temp_scale_max(peak) }.uniq).to eq([ 60 ])
    end

    it "server_temp_peak: massimo del periodo arrotondato per eccesso, nil senza misure" do
      expect(helper.server_temp_peak([ { temp: 41.0 }, { temp: 58.2 } ])).to eq(59)
      expect(helper.server_temp_peak([ { temp: nil } ])).to be_nil
    end

    it "server_current_text: assoluto + percentuale col totale, percentuale sola senza" do
      gib = 1_073_741_824

      expect(helper.server_current_text(57.3, total_bytes: 32 * gib)).to eq("18.3 GB · 57.3%")
      expect(helper.server_current_text(57.3)).to eq("57.3%")
      expect(helper.server_current_text(57.3, total_bytes: 0)).to eq("57.3%")
      expect(helper.server_current_text(nil, total_bytes: 32 * gib)).to eq("—")
      expect(helper.server_current_text(42.0, temp: true)).to eq("42°")
    end

    it "server_metric_total_bytes: memoria dalla colonna host, disco dal payload in GiB" do
      gib = 1_073_741_824
      host = Struct.new(:memory_total_bytes)
      sample = Struct.new(:payload)

      expect(helper.server_metric_total_bytes(:mem, host.new(32 * gib), nil)).to eq(32 * gib)
      expect(helper.server_metric_total_bytes(:mem, host.new(nil), sample.new({ "mem" => { "total_gb" => 16.0 } })))
        .to eq(16 * gib)
      expect(helper.server_metric_total_bytes(:disk, host.new(32 * gib), sample.new({ "disk" => { "total_gb" => 42.0 } })))
        .to eq(42 * gib)
    end

    it "server_metric_total_bytes: totale ignoto → nil, così il grafico resta in sola percentuale" do
      host = Struct.new(:memory_total_bytes)
      sample = Struct.new(:payload)

      expect(helper.server_metric_total_bytes(:mem, host.new(nil), nil)).to be_nil
      expect(helper.server_metric_total_bytes(:disk, host.new(nil), nil)).to be_nil
      expect(helper.server_metric_total_bytes(:disk, host.new(nil), sample.new({ "disk" => { "total_gb" => 0 } }))).to be_nil
      expect(helper.server_metric_total_bytes(:cpu, host.new(1024), nil)).to be_nil
    end

    it "server_chart_summary: dichiara la scala anche a chi legge con lo screen reader" do
      expect(helper.server_chart_summary("CPU", "24h", metric: :cpu)).to include("100%")
      expect(helper.server_chart_summary("Memoria", "24h", metric: :mem, total_bytes: 32 * 1_073_741_824)).to include("32 GB")
      expect(helper.server_chart_summary("Temperatura", "24h", metric: :temp, buckets: [ { count: 1, temp: 58.0 } ])).to include("60°")
    end

    it "server_chart_summary: senza un massimo dichiarabile resta la forma base" do
      summary = helper.server_chart_summary("Temperatura", "24h", metric: :temp, buckets: [ { count: 1, temp: nil } ])

      expect(summary).to eq(I18n.t("member.servers.show.chart_summary", metric: "Temperatura", range: "24h"))
    end
  end

  describe "#server_filesystems (i dischi della macchina, CYRA-472)" do
    let(:host) { Struct.new(:memory_total_bytes).new(nil) }
    let(:sample) { Struct.new(:payload) }

    it "mette per primo il disco di sistema, l'unico a cui si riferisce la percentuale del grafico" do
      payload = sample.new({ "disk" => { "total_gb" => 42.0, "used_gb" => 20.2 },
                             "extra_fs" => { "pgdata" => { "d" => 1000.0, "du" => 930.0 } } })

      disks = helper.server_filesystems(host, payload)

      expect(disks.first).to include(root: true, name: I18n.t("member.servers.show.disk_root"))
      expect(disks.last).to include(root: false, name: "pgdata")
    end

    it "calcola lo spazio libero, che è il numero su cui si decide se intervenire" do
      payload = sample.new({ "disk" => { "total_gb" => 42.0, "used_gb" => 20.2 } })

      root = helper.server_filesystems(host, payload).first

      expect(root[:free_bytes]).to eq(((42.0 - 20.2) * 1_073_741_824).round)
      expect(helper.server_filesystem_free_text(root))
        .to eq(I18n.t("member.servers.show.disk_free", free: "21.8 GB", total: "42 GB"))
    end

    it "un volume dati quasi pieno si vede anche quando il disco di sistema è tranquillo" do
      # Il caso che il ticket voleva far emergere: root al 48%, il volume del database al 93%.
      payload = sample.new({ "disk" => { "total_gb" => 42.0, "used_gb" => 20.2 },
                             "extra_fs" => { "pgdata" => { "d" => 1000.0, "du" => 930.0 } } })

      disks = helper.server_filesystems(host, payload)

      expect(disks.first[:pct]).to be < ServersHelper::PCT_WARN
      expect(disks.last[:pct]).to be >= ServersHelper::PCT_CRIT
      expect(helper.server_pct_color(disks.last[:pct])).to eq("text-red-600 dark:text-red-400")
    end

    it "senza payload, senza dischi o con un totale a zero non inventa righe" do
      expect(helper.server_filesystems(host, nil)).to eq([])
      expect(helper.server_filesystems(host, sample.new({}))).to eq([])
      expect(helper.server_filesystems(host, sample.new({ "disk" => { "total_gb" => 0 } }))).to eq([])
    end
  end

  describe "#server_size_short (etichette asse Y, gutter da 32px)" do
    it "usa l'unità a una lettera e non manda a capo" do
      expect(helper.server_size_short(800)).to eq("800B")
      expect(helper.server_size_short(800 * 1024)).to eq("800K")
      expect(helper.server_size_short(9.36 * 1024**3)).to eq("9.4G")
      expect(helper.server_size_short(0)).to eq("0B")
    end
  end

  describe "#server_size_change_text" do
    it "mostra il segno della variazione e distingue l'assenza di crescita" do
      expect(helper.server_size_change_text(1024)).to start_with("+")
      expect(helper.server_size_change_text(-1024)).to start_with("−")
      expect(helper.server_size_change_text(0)).to eq(I18n.t("member.databases.show.change_none"))
      expect(helper.server_size_change_text(nil)).to eq(I18n.t("member.databases.show.change_none"))
      expect(helper.server_size_change_color(2048)).to eq(:amber)
      expect(helper.server_size_change_color(-2048)).to eq(:emerald)
      expect(helper.server_size_change_color(nil)).to eq(:gray)
    end
  end

  describe "stato leggibile delle azioni operative" do
    let(:action) { build(:server_action, created_at: Time.current, status: :queued) }

    it "server_action_status_color: attesa ambra, in corso azzurro, esito verde o rosso" do
      expect(helper.server_action_status_color(build(:server_action, status: :queued))).to eq(:amber)
      expect(helper.server_action_status_color(build(:server_action, status: :running))).to eq(:sky)
      expect(helper.server_action_status_color(build(:server_action, status: :succeeded))).to eq(:emerald)
      expect(helper.server_action_status_color(build(:server_action, status: :failed))).to eq(:red)
      expect(helper.server_action_status_color(build(:server_action, status: :cancelled))).to eq(:gray)
    end

    # Il punto del ticket: "in attesa" da solo non basta, deve dire che l'attesa è prevista e quanto
    # dura, altrimenti chi guarda conclude che l'azione non è partita.
    it "server_action_detail spiega l'attesa invece di limitarsi allo stato" do
      I18n.with_locale(:it) do
        expect(helper.server_action_detail(action)).to include("entro un minuto")
      end
    end

    it "server_action_detail riporta orario ed esito delle azioni concluse" do
      done = build(:server_action, status: :succeeded, finished_at: Time.current)
      ko = build(:server_action, status: :failed, exit_code: 100, finished_at: Time.current)

      I18n.with_locale(:it) do
        expect(helper.server_action_detail(done)).to include("Completata")
        expect(helper.server_action_detail(ko)).to include("Fallita").and include("100")
      end
    end

    it "server_action_detail non esplode se finished_at manca su una riga storica" do
      orphan = build(:server_action, status: :succeeded, finished_at: nil, updated_at: Time.current)

      expect { helper.server_action_detail(orphan) }.not_to raise_error
    end

    it "server_action_detail copre annullata e scaduta" do
      cancelled = build(:server_action, status: :cancelled, finished_at: Time.current)
      expired = build(:server_action, status: :expired)

      I18n.with_locale(:it) do
        expect(helper.server_action_detail(cancelled)).to be_present
        expect(helper.server_action_detail(expired)).to be_present
      end
    end

    # CYRA-809 — "interrotta" non è né riuscita né fallita: la riga deve dire che l'esito non si sa,
    # altrimenti chi guarda la legge come un fallimento e rifà a mano un lavoro forse già fatto.
    it "server_action_status_color: interrotta in ambra, non nel grigio delle concluse" do
      expect(helper.server_action_status_color(build(:server_action, status: :interrupted))).to eq(:amber)
    end

    it "server_action_detail dice che l'esito di un'azione interrotta non si conosce" do
      interrupted = build(:server_action, status: :interrupted, started_at: Time.current,
                          finished_at: Time.current)

      I18n.with_locale(:it) do
        expect(helper.server_action_detail(interrupted)).to include("non sappiamo")
      end
    end
  end

  # Formattatori puri: il valore assente NON è zero e ogni caso ha una forma sua. Sono i rami che
  # una pagina esercita solo con i dati giusti sotto, e che qui si verificano direttamente.
  describe "formattatori" do
    it "server_bytes_text distingue assente da zero" do
      expect(helper.server_bytes_text(nil)).to eq("—")
      expect(helper.server_bytes_text(2048)).to include("KB")
    end

    it "server_uptime_text passa da ore a giorni" do
      expect(helper.server_uptime_text(0)).to eq("—")
      expect(helper.server_uptime_text(7200)).to eq("2h")
      expect(helper.server_uptime_text(3.days.to_i)).to include("3")
    end

    it "server_time_ago e server_data_age_text tacciono senza dato" do
      expect(helper.server_time_ago(nil)).to eq("—")
      expect(helper.server_time_ago(2.minutes.ago)).to be_present
    end

    it "server_threshold_pct compatta la soglia, nil se non c'è" do
      expect(helper.server_threshold_pct(nil)).to be_nil
      expect(helper.server_threshold_pct(80.0)).to eq("80%")
    end

    it "server_bucket_height e server_chart_height(:temp) tengono il minimo visibile" do
      expect(helper.server_bucket_height(nil)).to eq(0)
      expect(helper.server_bucket_height(1)).to eq(4)
      expect(helper.server_bucket_height(120)).to eq(100)
      expect(helper.server_chart_height(nil, :temp, scale: 100)).to eq(6)
      expect(helper.server_chart_height(50, :temp, scale: 0)).to eq(0)
      expect(helper.server_chart_height(50, :temp, scale: 100)).to eq(50)
    end

    it "server_smart_color promuove solo PASSED" do
      expect(helper.server_smart_color("PASSED")).to eq(:emerald)
      expect(helper.server_smart_color("FAILED")).to eq(:red)
    end

    it "server_journal_priority_class colora per gravità" do
      expect(helper.server_journal_priority_class(1)).to include("red")
      expect(helper.server_journal_priority_class(3)).to include("amber")
      expect(helper.server_journal_priority_class(6)).to include("stone")
    end

    # CYRA-456 — la cella si accende sopra la soglia della macchina, o sopra il limite critico
    # generale quando quella soglia non c'è.
    it "server_cell_class accende la cella solo dove serve" do
      expect(helper.server_cell_class(nil, 80)).to eq("")
      expect(helper.server_cell_class(95, 80)).to eq("bg-rose-50 dark:bg-rose-500/15")
      expect(helper.server_cell_class(74, 80)).to eq("bg-amber-50 dark:bg-amber-500/15")
      expect(helper.server_cell_class(10, 80)).to eq("")
      expect(helper.server_cell_class(99, nil)).to eq("bg-rose-50 dark:bg-rose-500/15")
      expect(helper.server_cell_class(10, nil)).to eq("")
    end
  end

  # CYRA-463 — le unit ferme non sono tutte uguali: una oneshot completata o un servizio di
  # sistema notoriamente a riposo non è un guasto. Senza lo stato enabled (che l'agent non manda)
  # la distinzione è un'euristica conservativa: una unit sconosciuta resta "ferma" (visibile), mai
  # nascosta.
  describe "distinzione delle unit systemd ferme (CYRA-463)" do
    it "server_systemd_kind: failed/active/transizione restano tali" do
      expect(helper.server_systemd_kind("state" => "failed", "sub" => "failed")).to eq(:failed)
      expect(helper.server_systemd_kind("state" => "active", "sub" => "running")).to eq(:active)
      expect(helper.server_systemd_kind("state" => "activating", "sub" => "start")).to eq(:transitioning)
      expect(helper.server_systemd_kind("state" => "deactivating", "sub" => "stop")).to eq(:transitioning)
    end

    it "server_systemd_kind: unit ferma nota o oneshot completata è :idle" do
      expect(helper.server_systemd_kind("name" => "dmesg.service", "state" => "inactive", "sub" => "dead")).to eq(:idle)
      expect(helper.server_systemd_kind("name" => "systemd-fsck@dev-sda1.service", "state" => "inactive", "sub" => "dead")).to eq(:idle)
      expect(helper.server_systemd_kind("name" => "apt-daily-upgrade.service", "state" => "inactive", "sub" => "dead")).to eq(:idle)
      expect(helper.server_systemd_kind("name" => "backup.service", "state" => "inactive", "sub" => "exited")).to eq(:idle)
    end

    it "server_systemd_kind: unit ferma sconosciuta è :stopped, mai nascosta" do
      expect(helper.server_systemd_kind("name" => "myapp.service", "state" => "inactive", "sub" => "dead")).to eq(:stopped)
      expect(helper.server_systemd_kind("name" => "postgresql@main.service", "state" => "inactive", "sub" => "dead")).to eq(:stopped)
    end

    it "server_systemd_note annota solo le unit ferme, in parole" do
      expect(helper.server_systemd_note("state" => "active", "sub" => "running")).to be_nil
      expect(helper.server_systemd_note("state" => "failed", "sub" => "failed")).to be_nil
      expect(helper.server_systemd_note("name" => "dmesg.service", "state" => "inactive", "sub" => "dead"))
        .to eq(I18n.t("member.servers.show.systemd_rest.idle"))
      expect(helper.server_systemd_note("name" => "myapp.service", "state" => "inactive", "sub" => "dead"))
        .to eq(I18n.t("member.servers.show.systemd_rest.stopped"))
    end
  end

  # Colore, freccia e taglio dell'immagine sono ciò che si legge a colpo d'occhio nella lista dei
  # server: una variazione che cresce colorata come una che cala, o un nome d'immagine tagliato dalla
  # parte sbagliata, ingannano proprio nel momento in cui si guarda di fretta.
  describe "#server_size_change_class" do
    it "ambra se cresce, verde se cala, grigio se fermo o assente" do
      expect(helper.server_size_change_class(1_000)).to eq("text-amber-600 dark:text-amber-400")
      expect(helper.server_size_change_class(-1_000)).to eq("text-emerald-600 dark:text-emerald-400")
      expect(helper.server_size_change_class(0)).to eq("text-gray-500 dark:text-zinc-400")
      expect(helper.server_size_change_class(nil)).to eq("text-gray-500 dark:text-zinc-400")
    end
  end

  describe "#server_size_change_icon" do
    it "freccia su se cresce, giù se cala, niente se fermo o assente" do
      expect(helper.server_size_change_icon(10)).to eq("arrow-up")
      expect(helper.server_size_change_icon(-10)).to eq("arrow-down")
      expect(helper.server_size_change_icon(0)).to be_nil
      expect(helper.server_size_change_icon(nil)).to be_nil
    end
  end

  describe "#server_container_image" do
    it "taglia a sinistra, perché il nome del programma sta in coda" do
      lunga = "registry.esempio.it/organizzazione/progetto/servizio:v1.2.3"
      tagliata = helper.server_container_image(lunga, max: 20)

      expect(tagliata).to start_with("…")
      expect(tagliata).to end_with("v1.2.3")
      expect(tagliata.length).to eq(20)
    end

    it "lascia intatto un nome che ci sta, e segna con un trattino quello assente" do
      expect(helper.server_container_image("nginx:1.27")).to eq("nginx:1.27")
      expect(helper.server_container_image(nil)).to eq("—")
      expect(helper.server_container_image("")).to eq("—")
    end
  end

  describe "metriche non percentuali (CYRA-703)" do
    def blocco(valori) = { count: 1, at: Time.current }.merge(valori)

    describe "#server_metric_kind" do
      it "riconosce la famiglia di ogni metrica" do
        expect(helper.server_metric_kind(:cpu)).to eq(:pct)
        expect(helper.server_metric_kind(:gpu)).to eq(:pct)
        expect(helper.server_metric_kind(:temp)).to eq(:temp)
        expect(helper.server_metric_kind(:gpu_watt)).to eq(:watt)
        expect(helper.server_metric_kind(:net)).to eq(:bytes)
      end

      it "tratta come percentuale una metrica che non conosce, invece di rompersi" do
        expect(helper.server_metric_kind(:inventata)).to eq(:pct)
      end
    end

    describe "#server_metric_value" do
      it "somma le due direzioni del traffico di rete" do
        expect(helper.server_metric_value(blocco(net_out: 300, net_in: 700), :net)).to eq(1_000)
      end

      it "sul traffico non inventa uno zero dove non è stato misurato niente" do
        expect(helper.server_metric_value({ count: 0, net_out: nil, net_in: nil }, :net)).to be_nil
      end

      it "per le altre metriche legge la propria chiave" do
        expect(helper.server_metric_value(blocco(gpu_watt: 11.2), :gpu_watt)).to eq(11.2)
      end
    end

    describe "#server_chart_bars" do
      it "scala i watt sul picco del periodo, non su cento" do
        blocchi = [ blocco(gpu_watt: 30.0), blocco(gpu_watt: 60.0) ]

        altezze = helper.server_chart_bars(blocchi, :gpu_watt, "30m").map { |b| b[:height] }

        expect(altezze.last).to eq(100)
        expect(altezze.first).to be_between(40, 60)
      end

      it "tiene le percentuali sul fondo scala fisso" do
        blocchi = [ blocco(cpu: 30.0), blocco(cpu: 60.0) ]

        altezze = helper.server_chart_bars(blocchi, :cpu, "30m").map { |b| b[:height] }

        expect(altezze).to eq([ 30, 60 ])
      end

      it "scrive il traffico in byte, non in percentuale" do
        barre = helper.server_chart_bars([ blocco(net_out: 500, net_in: 524) ], :net, "30m")

        expect(barre.first[:value_line]).not_to include("%")
      end
    end
  end
end
