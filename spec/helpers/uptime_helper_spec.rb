# frozen_string_literal: true

require "rails_helper"

RSpec.describe UptimeHelper, type: :helper do
  describe "#uptime_status_label / #uptime_status_color" do
    it "pausa ha precedenza sulla salute" do
      m = build(:uptime_monitor, active: false, current_status: :up)
      expect(helper.uptime_status_label(m)).to eq("Paused")
      expect(helper.uptime_status_color(m)).to eq(:gray)
    end

    it "up/down/unknown → label capitalizzata + colore" do
      up = build(:uptime_monitor, active: true, current_status: :up)
      down = build(:uptime_monitor, active: true, current_status: :down)
      unknown = build(:uptime_monitor, active: true, current_status: :unknown)
      expect(helper.uptime_status_label(up)).to eq("Up")
      expect(helper.uptime_status_color(up)).to eq(:emerald)
      expect(helper.uptime_status_color(down)).to eq(:red)
      expect(helper.uptime_status_color(unknown)).to eq(:gray)
    end

    it "dato vecchio (worker fermo): unknown/grigio anche se l'ultimo stato era up (CYRA-209)" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        stale = build(:uptime_monitor, active: true, current_status: :up, last_checked_at: 1.hour.ago)
        expect(helper.uptime_status_label(stale)).to eq("Unknown")
        expect(helper.uptime_status_color(stale)).to eq(:gray)
      end
    end
  end

  describe "#uptime_percent_color (soglie)" do
    it "nil → grigio; ≥99.5 verde; ≥98 ambra; sotto rosso" do
      expect(helper.uptime_percent_color(nil)).to eq("text-gray-400 dark:text-zinc-500")
      expect(helper.uptime_percent_color(100.0)).to eq("text-emerald-700 dark:text-emerald-300")
      expect(helper.uptime_percent_color(98.5)).to eq("text-amber-700 dark:text-amber-300")
      expect(helper.uptime_percent_color(80.0)).to eq("text-red-600 dark:text-red-400")
    end
  end

  describe "#uptime_percent_text" do
    it "nil → trattino, valore → percentuale compatta" do
      expect(helper.uptime_percent_text(nil)).to eq("—")
      expect(helper.uptime_percent_text(99.97)).to eq("99.97%")
      expect(helper.uptime_percent_text(100.0)).to eq("100%")
    end

    it "in italiano usa la virgola decimale" do
      I18n.with_locale(:it) { expect(helper.uptime_percent_text(99.97)).to eq("99,97%") }
    end
  end

  describe "#uptime_bucket_class / #uptime_bucket_title" do
    it "mappa lo stato del blocco al colore Tailwind" do
      expect(helper.uptime_bucket_class(:up)).to eq("bg-emerald-300")
      expect(helper.uptime_bucket_class(:partial)).to eq("bg-amber-300")
      expect(helper.uptime_bucket_class(:down)).to eq("bg-red-400")
      expect(helper.uptime_bucket_class(:empty)).to eq("bg-stone-200/80 dark:bg-zinc-700/80")
    end

    it "tooltip: vuoto → 'no data'; con dato → stato + up/total + ms" do
      expect(helper.uptime_bucket_title(status: :empty, total: 0, up: 0, avg_ms: nil)).to eq("No data")
      expect(helper.uptime_bucket_title(status: :up, total: 30, up: 30, avg_ms: 40)).to include("30/30 up", "40ms")
      expect(helper.uptime_bucket_title(status: :down, total: 30, up: 0, avg_ms: nil)).not_to include("ms")
    end
  end

  describe "#uptime_time_ago" do
    it "blank → trattino; presente → 'X fa'" do
      expect(helper.uptime_time_ago(nil)).to eq("—")
      expect(helper.uptime_time_ago(2.minutes.ago)).to be_present
      expect(helper.uptime_time_ago(2.minutes.ago)).not_to eq("—")
    end
  end

  # CYRA-492 — durante un guasto la prima domanda è «da quanto?»: l'elenco deve rispondere senza aprire
  # il monitor.
  describe "#uptime_down_since (durata del guasto in corso)" do
    it "durata compatta a due unità dall'inizio del guasto" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        expect(helper.uptime_down_since(3.hours.ago - 9.minutes)).to eq(
          I18n.t("member.uptime.down_since", duration: "3h 09m")
        )
      end
    end

    it "sotto l'ora usa minuti e secondi; sotto il minuto solo secondi" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        expect(helper.uptime_down_since(12.minutes.ago - 9.seconds)).to include("12m 09s")
        expect(helper.uptime_down_since(45.seconds.ago)).to include("45s")
      end
    end
  end

  describe "#uptime_last_cell (colonna tempo: durata se giù, ultimo check altrimenti)" do
    it "sito giù (fresco) con guasto noto → 'Giù da …' in rosso, non l'ora dell'ultimo check" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        m = build(:uptime_monitor, current_status: :down, last_checked_at: 30.seconds.ago)
        html = helper.uptime_last_cell(m, 2.hours.ago)
        expect(html).to include(I18n.t("member.uptime.down_since", duration: "2h 00m"))
        expect(html).to include("monitor-down-since")
        expect(html).to include("text-red-600 dark:text-red-400")
      end
    end

    it "sito su → resta l'ora dell'ultimo controllo" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        m = build(:uptime_monitor, current_status: :up, last_checked_at: 2.minutes.ago)
        expect(helper.uptime_last_cell(m, nil)).to eq(helper.uptime_time_ago(m.last_checked_at))
      end
    end

    it "giù ma col dato vecchio (mostrato unknown) → non promette una durata, torna all'ultimo check" do
      travel_to(Time.utc(2026, 6, 26, 12)) do
        m = build(:uptime_monitor, current_status: :down, last_checked_at: 1.hour.ago)
        expect(helper.uptime_last_cell(m, 3.hours.ago)).to eq(helper.uptime_time_ago(m.last_checked_at))
      end
    end
  end

  describe "#uptime_status_chip_active? (contatore-filtro dell'header)" do
    it "acceso solo quando quel filtro di stato è l'unico in vigore" do
      allow(helper).to receive(:params).and_return(ActionController::Parameters.new(status: [ "down" ]))
      expect(helper.uptime_status_chip_active?("down")).to be(true)
      expect(helper.uptime_status_chip_active?("up")).to be(false)
    end

    it "spento senza filtro o con più stati selezionati" do
      allow(helper).to receive(:params).and_return(ActionController::Parameters.new({}))
      expect(helper.uptime_status_chip_active?("down")).to be(false)
      allow(helper).to receive(:params).and_return(ActionController::Parameters.new(status: %w[up down]))
      expect(helper.uptime_status_chip_active?("down")).to be(false)
    end
  end
end
