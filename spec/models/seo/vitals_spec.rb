# frozen_string_literal: true

require "rails_helper"

# CYRA-537 — le soglie con cui Google decide se un sito è veloce. Stanno in un posto solo, e questo
# guard le confronta coi valori ufficiali: se qualcuno le ritocca «per far tornare i numeri», la
# pagina smette di dire quello che dice Google e nessuno se ne accorge guardandola.
RSpec.describe Seo::Vitals do
  describe "le soglie ufficiali" do
    # Fonte: web.dev/articles/vitals (LCP, CLS), web.dev/articles/inp, /fcp, /ttfb. Tutte a p75.
    UFFICIALI = {
      "lcp" => [ 2_500, 4_000 ],
      "inp" => [ 200, 500 ],
      "cls" => [ 0.1, 0.25 ],
      "ttfb" => [ 800, 1_800 ],
      "fcp" => [ 1_800, 3_000 ]
    }.freeze

    it "sono quelle pubblicate da Google, per ogni metrica" do
      expect(described_class::THRESHOLDS).to eq(UFFICIALI)
    end

    it "il punteggio di Lighthouse è buono da 90 e scarso sotto 50" do
      expect(described_class::SCORE_THRESHOLDS).to eq([ 50, 90 ])
    end

    it "il percentile è il 75° e la finestra di campo 28 giorni, come quella di Google" do
      expect(described_class::PERCENTILE).to eq(75)
      expect(described_class::FIELD_WINDOW_DAYS).to eq(28)
    end
  end

  describe ".rating" do
    it "classifica una misura nelle tre fasce, estremi compresi" do
      expect(described_class.rating("lcp", 2_500)).to eq(:good)
      expect(described_class.rating("lcp", 2_501)).to eq(:needs_improvement)
      expect(described_class.rating("lcp", 4_000)).to eq(:needs_improvement)
      expect(described_class.rating("lcp", 4_001)).to eq(:poor)
    end

    it "il CLS si giudica su valori piccoli e adimensionali" do
      expect(described_class.rating("cls", 0.05)).to eq(:good)
      expect(described_class.rating("cls", 0.3)).to eq(:poor)
      expect(described_class).to be_unitless("cls")
      expect(described_class).not_to be_unitless("lcp")
    end

    # Una misura che non abbiamo non è "buona": senza questo, una colonna vuota si dipingerebbe di
    # verde e direbbe il contrario di quello che sa.
    it "una misura assente o una metrica ignota non ricevono un esito di comodo" do
      expect(described_class.rating("lcp", nil)).to be_nil
      expect(described_class.rating("mai_sentita", 10)).to be_nil
    end
  end

  describe ".score_rating" do
    it "classifica il punteggio di Lighthouse" do
      expect(described_class.score_rating(95)).to eq(:good)
      expect(described_class.score_rating(90)).to eq(:good)
      expect(described_class.score_rating(89)).to eq(:needs_improvement)
      expect(described_class.score_rating(49)).to eq(:poor)
    end

    # Google manda `null` quando non è riuscito a calcolare un punteggio. Trattarlo come zero
    # dipingerebbe di rosso un sito che nessuno ha misurato: è la trappola peggiore di quell'API.
    it "un punteggio nullo resta nullo, non diventa zero" do
      expect(described_class.score_rating(nil)).to be_nil
    end
  end

  describe "il vocabolario" do
    %i[it en].each do |lingua|
      it "in #{lingua} ogni metrica e ogni esito hanno un nome" do
        described_class::METRICS.each do |metrica|
          expect(I18n.t("seo.vitals.metrics.#{metrica}", locale: lingua, default: "")).to be_present
          expect(I18n.t("seo.vitals.metric_help.#{metrica}", locale: lingua, default: "")).to be_present
        end
        described_class::RATINGS.each do |esito|
          expect(I18n.t("seo.vitals.ratings.#{esito}", locale: lingua, default: "")).to be_present
        end
      end
    end

    # Laboratorio e campo sono due risposte a due domande diverse. La pagina lo dice una volta, con
    # queste due righe: senza, il lettore le media in testa e ottiene un numero che non esiste.
    it "dichiara la differenza fra laboratorio e campo, in entrambe le lingue" do
      %i[it en].each do |lingua|
        expect(I18n.t("seo.vitals.lab_explainer", locale: lingua, default: "")).to be_present
        expect(I18n.t("seo.vitals.field_explainer", locale: lingua, default: "")).to be_present
      end
    end
  end
end
