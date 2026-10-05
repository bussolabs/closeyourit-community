# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticsHelper, type: :helper do
  describe "#analytics_chart_bars (view-model per Ui::HistogramComponent)" do
    let(:at) { Time.zone.local(2026, 7, 2, 12, 0, 0) }

    it "mappa i bucket a height ∝ pageviews, colore indigo, finestra oraria e riga valore = visitatori" do
      buckets = [ { pageviews: 4, visitors: 2, at: at }, { pageviews: 8, visitors: 5, at: at + 10_800 } ]

      bars = helper.analytics_chart_bars(buckets, 8, "7d")

      expect(bars.length).to eq(2)
      expect(bars.first).to include(height: 50, color_class: "bg-indigo-500")
      expect(bars.first[:value_line]).to eq(I18n.t("member.monitoring.analytics.tooltip_visitors", count: 2))
      expect(bars.first[:time_label]).to be_present
      expect(bars.last).to include(height: 100, color_class: "bg-indigo-500")
      expect(bars.last[:value_line]).to eq(I18n.t("member.monitoring.analytics.tooltip_visitors", count: 5))
    end

    it "bucket vuoto (0 pageview): stub height 6, traccia grigia, riga con 0 visitatori" do
      bars = helper.analytics_chart_bars([ { pageviews: 0, visitors: 0, at: at } ], 8, "7d")

      expect(bars.first).to include(height: 6, color_class: "bg-stone-200 dark:bg-zinc-700")
      expect(bars.first[:value_line]).to eq(I18n.t("member.monitoring.analytics.tooltip_visitors", count: 0))
    end

    # CYRA-570 — cinquantasei barrette identiche sopra il riquadro che dichiara il periodo vuoto:
    # il flag permette al grafico di dire la stessa cosa invece di disegnare valori che non esistono.
    it "marca i bucket senza pageview, così un periodo vuoto si può dichiarare" do
      bars = helper.analytics_chart_bars([ { pageviews: 4, visitors: 2, at: at },
                                           { pageviews: 0, visitors: 0, at: at + 3_600 } ], 4, "7d")

      expect(bars.first[:empty]).to be(false)
      expect(bars.last[:empty]).to be(true)
    end
  end

  # CYRA-500 — la variazione rispetto al periodo precedente: il colore dice se è una buona notizia
  # solo dove ha senso, e senza una base non si inventa nessun delta.
  describe "#analytics_trend" do
    it "senza un periodo precedente non produce niente" do
      expect(helper.analytics_trend(10, nil)).to be_nil
      expect(helper.analytics_trend(10, 0)).to be_nil
      expect(helper.analytics_trend(nil, 10)).to be_nil
    end

    it "in salita e in discesa scrive il verso e la percentuale" do
      expect(helper.analytics_trend(150, 100)[:label]).to eq("▲ 50%")
      expect(helper.analytics_trend(50, 100)[:label]).to eq("▼ 50%")
    end

    it "stabile lo dice, senza freccia" do
      trend = helper.analytics_trend(100, 100)

      expect(trend[:label]).to eq(I18n.t("member.monitoring.analytics.comparison.flat"))
      expect(trend[:color]).to eq(:gray)
    end

    it "il colore giudica solo dove «di più» è davvero meglio o peggio" do
      expect(helper.analytics_trend(150, 100)[:color]).to eq(:gray)
      expect(helper.analytics_trend(150, 100, lower_is_better: true)[:color]).to eq(:rose)
      expect(helper.analytics_trend(50, 100, lower_is_better: true)[:color]).to eq(:emerald)
      expect(helper.analytics_trend(150, 100, lower_is_better: false)[:color]).to eq(:emerald)
      expect(helper.analytics_trend(50, 100, lower_is_better: false)[:color]).to eq(:rose)
    end
  end

  # CYRA-497 — i canali arrivano dal dato con nomi inglesi: si traduce solo l'etichetta letta.
  describe "#analytics_channel_label" do
    it "traduce i canali conosciuti" do
      I18n.with_locale(:it) do
        expect(helper.analytics_channel_label("Organic Social")).to eq("Social")
        expect(helper.analytics_channel_label("Direct")).to eq("Accesso diretto")
      end
    end

    it "un canale nuovo resta col suo nome invece di sparire" do
      expect(helper.analytics_channel_label("Teleport")).to eq("Teleport")
    end
  end

  # CYRA-500 — la didascalia del grafico dice da quando a quando.
  describe "#analytics_window_label" do
    it "senza blocchi ricade sulla forma vecchia invece di rompersi" do
      expect(helper.analytics_window_label([], "24h")).to include("24h")
    end

    it "coi blocchi scrive le date vere del periodo" do
      blocchi = [ { at: 2.days.ago, pageviews: 1 }, { at: 1.day.ago, pageviews: 2 } ]

      expect(helper.analytics_window_label(blocchi, "24h")).to include(I18n.l(2.days.ago.to_date, format: :day_month_year))
    end
  end
end
