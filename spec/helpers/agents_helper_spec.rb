# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentsHelper, type: :helper do
  def host(**attrs)
    build(:agent_host, heartbeat_expected_interval_minutes: 2, heartbeat_grace_minutes: 1, **attrs)
  end

  describe "#agent_host_status_color / #agent_host_status_pulse?" do
    it "online idle → emerald, nessun pulse" do
      h = host(last_heartbeat_at: 30.seconds.ago, host_status: "idle")
      expect(helper.agent_host_status_color(h)).to eq(:emerald)
      expect(helper.agent_host_status_pulse?(h)).to be(false)
    end

    it "busy → indigo con pulse" do
      h = host(last_heartbeat_at: 30.seconds.ago, host_status: "busy")
      expect(helper.agent_host_status_color(h)).to eq(:indigo)
      expect(helper.agent_host_status_pulse?(h)).to be(true)
    end

    it "offline → gray" do
      h = host(last_heartbeat_at: 10.minutes.ago, host_status: "idle")
      expect(helper.agent_host_status_color(h)).to eq(:gray)
    end

    # CYRA-450 — un host fermo (offline oltre la soglia) è allarme, non semplice offline grigio.
    it "fermo (stale) → red con etichetta dedicata, non pulse" do
      h = host(last_heartbeat_at: 20.minutes.ago, host_status: "idle")
      expect(helper.agent_host_status_color(h)).to eq(:red)
      expect(helper.agent_host_status_label(h)).to eq(t("member.agents.status.stale"))
      expect(helper.agent_host_status_pulse?(h)).to be(false)
    end
  end

  describe "#agent_host_stale?" do
    it "offline sotto la soglia non è fermo; oltre la soglia sì" do
      expect(helper.agent_host_stale?(host(last_heartbeat_at: 10.minutes.ago))).to be(false)
      expect(helper.agent_host_stale?(host(last_heartbeat_at: 20.minutes.ago))).to be(true)
    end
  end

  describe "#agent_host_time_ago" do
    it "nil → trattino" do
      expect(helper.agent_host_time_ago(nil)).to eq("—")
    end

    it "valorizzato → stringa presente" do
      expect(helper.agent_host_time_ago(3.minutes.ago)).to be_present
      expect(helper.agent_host_time_ago(3.minutes.ago)).not_to eq("—")
    end
  end

  describe "#agent_duration" do
    it "sotto il minuto resta in secondi" do
      expect(helper.agent_duration(45)).to eq("45s")
    end

    it "sopra il minuto affianca i secondi con lo zero davanti" do
      expect(helper.agent_duration(90)).to eq("1m 30s")
      expect(helper.agent_duration(609)).to eq("10m 09s")
    end

    it "sopra l'ora scende a ore e minuti" do
      expect(helper.agent_duration(3600)).to eq("1h 00m")
      expect(helper.agent_duration(11_100)).to eq("3h 05m")
    end

    # La sigla del giorno cambia con la lingua (g/d): scritta nel codice farebbe comparire "2g 4h"
    # in mezzo a una pagina inglese.
    it "sopra il giorno scende a giorni e ore, con la sigla della lingua" do
      expect(I18n.with_locale(:it) { helper.agent_duration(187_200) }).to eq("2g 4h")
      expect(I18n.with_locale(:en) { helper.agent_duration(187_200) }).to eq("2d 4h")
    end

    # Una durata sconosciuta non è una durata di zero: "0s" farebbe leggere "istantaneo" dove il
    # dato manca, ed è il caso di un tentativo interrotto senza istante di fine.
    it "senza valore dà un trattino, mentre lo zero vero resta zero" do
      expect(helper.agent_duration(nil)).to eq("—")
      expect(helper.agent_duration(0)).to eq("0s")
    end
  end

  describe "#agent_host_activity_summary / #agent_host_stalled?" do
    # CYRA-450 — la colonna Attività non è mai vuota: senza run dichiarate mostra lo stato di attesa,
    # mai il trattino che rendeva un host a riposo indistinguibile da uno rotto.
    it "nessuna run → stato di attesa, non stalled" do
      h = host(last_heartbeat_at: 30.seconds.ago, active_runs: [])
      expect(helper.agent_host_activity_summary(h)).to eq(t("member.agents.activity.idle"))
      expect(helper.agent_host_stalled?(h)).to be(false)
    end

    it "una run → 'ticket · fase'" do
      h = host(last_heartbeat_at: 30.seconds.ago,
               active_runs: [ { "ticket" => "CYRA-31", "phase" => "autopilot" } ])
      expect(helper.agent_host_activity_summary(h)).to eq("CYRA-31 · autopilot")
    end

    it "più run → suffisso +N" do
      h = host(last_heartbeat_at: 30.seconds.ago,
               active_runs: [ { "ticket" => "CYRA-31", "phase" => "autopilot" },
                              { "ticket" => "CYRA-9", "phase" => "triage" } ])
      expect(helper.agent_host_activity_summary(h)).to eq("CYRA-31 · autopilot +1")
    end

    it "host offline con run dichiarate → stalled" do
      h = host(last_heartbeat_at: 10.minutes.ago,
               active_runs: [ { "ticket" => "CYRA-31", "phase" => "autopilot" } ])
      expect(helper.agent_host_stalled?(h)).to be(true)
    end
  end

  # CYRA-999 — the row explains why the machine stopped, using the most recent stop.
  describe "#agent_host_last_stop_reason" do
    it "returns the reason of the latest stop" do
      h = host(last_stops: [ { "action" => "a", "state" => "blocked", "reason" => "old" },
                             { "action" => "b", "state" => "waiting", "reason" => "empty ticket queue" } ])
      expect(helper.agent_host_last_stop_reason(h)).to eq("empty ticket queue")
    end

    it "returns nil without stops" do
      expect(helper.agent_host_last_stop_reason(host(last_stops: []))).to be_nil
    end
  end

  # Formattatori del rendimento: "nessun dato" e "zero" restano due cose diverse, e i colori
  # dirigono lo sguardo per fasce grossolane.
  describe "rendimento" do
    it "agent_percent distingue non misurato da zero" do
      expect(helper.agent_percent(nil)).to eq("—")
      expect(helper.agent_percent(21.6)).to include("21,6").or include("21.6")
      expect(helper.agent_percent(0)).to start_with("0")
    end

    it "agent_rejection_color colora per fasce" do
      expect(helper.agent_rejection_color(nil)).to eq(:neutral)
      expect(helper.agent_rejection_color(5)).to eq(:emerald)
      expect(helper.agent_rejection_color(21.6)).to eq(:amber)
      expect(helper.agent_rejection_color(38)).to eq(:red)
    end

    it "agent_count_class spegne gli zeri e segue il colore" do
      expect(helper.agent_count_class(0, :red)).to include("gray-300")
      expect(helper.agent_count_class(3, :emerald)).to include("green-600")
      expect(helper.agent_count_class(3, :red)).to include("red-600")
      expect(helper.agent_count_class(3, :amber)).to include("amber-600")
      expect(helper.agent_count_class(3, :neutral)).to include("gray-500")
    end

    it "agent_step_connector_class riempie il segmento solo dove il lavoro è arrivato" do
      expect(helper.agent_step_connector_class(:done)).to include("emerald")
      expect(helper.agent_step_connector_class(:pending)).to include("stone")
    end

    # CYRA-499 — un riquadro che mostra sempre un trattino occupa un quinto della riga senza dire
    # niente: una misura senza valore non si mostra affatto, e la griglia si stringe di conseguenza.
    describe "#agent_performance_tiles" do
      def outcomes = Agents::Hosts::Performance::Outcomes.new(approved: 4, rejected: 1, failed: 0, interrupted: 0, total: 5)

      def cost(tracked: 2) = Agents::Hosts::Performance::Cost.new(total: BigDecimal("2"), tracked:, untracked: 0)

      def report(host_seconds_avg: 300, workflow_seconds_avg: 7200, workflow_tickets_count: 2, cost_report: cost)
        Agents::Hosts::Performance::Report.new(
          range: "30d", tickets_count: 3, attempts_count: 5, outcomes:, cost: cost_report,
          plans_total: 0, plans_sent_back: 0,
          host_seconds_avg:, host_seconds_median: host_seconds_avg,
          workflow_seconds_avg:, workflow_seconds_median: workflow_seconds_avg,
          workflow_tickets_count:, by_phase: []
        )
      end

      it "con tutte le misure disponibili rende i cinque riquadri" do
        tiles = helper.agent_performance_tiles(report, nil)

        expect(tiles.map { |tile| tile[:test_id] })
          .to eq(%w[perf-tickets perf-rejected perf-host-time perf-workflow-time perf-cost])
      end

      it "toglie il riquadro della misura che non ha un valore, invece di mostrare un trattino" do
        tiles = helper.agent_performance_tiles(
          report(workflow_seconds_avg: nil, workflow_tickets_count: 0, cost_report: cost(tracked: 0)), nil
        )

        expect(tiles.map { |tile| tile[:test_id] }).to eq(%w[perf-tickets perf-rejected perf-host-time])
        expect(tiles.map { |tile| tile[:value].to_s }).not_to include("—")
      end

      it "sotto il tempo di lavorazione dice su quante lavorazioni chiuse è calcolato" do
        tile = helper.agent_performance_tiles(report(workflow_tickets_count: 2), nil)
                     .find { |t| t[:test_id] == "perf-workflow-time" }

        expect(tile[:caption]).to eq(t("member.agents.performance.workflow_median_caption",
                                       value: helper.agent_duration(7200), count: 2))
      end

      it "la griglia si stringe sul numero di riquadri, con classi che Tailwind vede" do
        expect(helper.agent_tiles_grid_class(5)).to eq("lg:grid-cols-5")
        expect(helper.agent_tiles_grid_class(3)).to eq("lg:grid-cols-3")
        expect(helper.agent_tiles_grid_class(1)).to eq("lg:grid-cols-2")
      end
    end

    # CYRA-499 — stessa regola nel confronto fra macchine: una riga vuota su ogni colonna non è un
    # confronto, è una domanda senza risposta.
    describe "#agent_compare_rows" do
      def comparison_row(workflow_seconds_median:)
        Agents::Hosts::Comparison::Row.new(
          host_id: SecureRandom.uuid, tickets_count: 3, attempts_count: 5, rejected: 1, interrupted: 0,
          host_seconds_median: 300, workflow_seconds_median:,
          cost: Agents::Hosts::Performance::Cost.new(total: BigDecimal("1"), tracked: 1, untracked: 0)
        )
      end

      it "toglie il tempo di lavorazione quando nessuna macchina lo ha misurato" do
        rows = helper.agent_compare_rows({ "a" => comparison_row(workflow_seconds_median: nil),
                                           "b" => comparison_row(workflow_seconds_median: nil) })

        expect(rows.map { |row| row[:key] }).not_to include("workflow_time")
      end

      it "lo tiene appena una macchina lo ha misurato" do
        rows = helper.agent_compare_rows({ "a" => comparison_row(workflow_seconds_median: 7200),
                                           "b" => comparison_row(workflow_seconds_median: nil) })

        expect(rows.map { |row| row[:key] }).to include("workflow_time")
      end
    end

    # La run arriva dall'host come jsonb: una data assente o storta non deve rompere la riga.
    it "agent_run_started_label si difende da una data assente o malformata" do
      expect(helper.agent_run_started_label({})).to be_nil
      expect(helper.agent_run_started_label({ "started_at" => "non-una-data" })).to be_nil
      expect(helper.agent_run_started_label({ "started_at" => 5.minutes.ago })).to be_present
      expect(helper.agent_run_started_label({ "started_at" => 5.minutes.ago.iso8601 })).to be_present
    end
  end
end
