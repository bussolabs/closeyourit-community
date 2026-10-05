# frozen_string_literal: true

require "rails_helper"

# CYRA-539 — il parser della risposta di PageSpeed Insights. Le tre trappole di questa API sono
# TUTTE silenziose: sbagliando, i numeri restano plausibili e nessuno se ne accorge guardandoli.
RSpec.describe Seo::PageSpeed::Parse do
  def fixture(nome) = JSON.parse(Rails.root.join("spec/fixtures/seo/#{nome}.json").read)

  subject(:attributi) { described_class.call(fixture("pagespeed_success")) }

  it "prende la URL canonica e la versione di Lighthouse" do
    expect(attributi[:final_url]).to eq("https://acme.example/")
    expect(attributi[:lighthouse_version]).to eq("12.8.2")
  end

  # Il punteggio arriva in 0..1, non in 0..100. Un'interpretazione sbagliata darebbe 0 o 1 su ogni
  # sito del mondo, che è esattamente il genere di errore che sembra "il sito è messo male".
  it "riporta i punteggi in centesimi" do
    expect(attributi[:performance_score]).to eq(72)
    expect(attributi[:accessibility_score]).to eq(94)
    expect(attributi[:best_practices_score]).to eq(100)
  end

  # LA trappola: Google manda `null` quando non è riuscito a calcolare un punteggio. Trattarlo come
  # zero dipinge di rosso un sito che nessuno ha misurato.
  it "un punteggio nullo non diventa zero: la colonna resta vuota" do
    expect(attributi).not_to have_key(:seo_score)
  end

  it "prende le misure di laboratorio arrotondate al millisecondo" do
    expect(attributi[:lab_lcp_ms]).to eq(2_842)
    expect(attributi[:lab_fcp_ms]).to eq(1_503)
    expect(attributi[:lab_tbt_ms]).to eq(310)
    expect(attributi[:lab_ttfb_ms]).to eq(619)
    expect(attributi[:lab_speed_index_ms]).to eq(3_910)
    expect(attributi[:lab_cls]).to eq(0.0421)
  end

  it "prende le misure dei visitatori veri che Google ha già" do
    expect(attributi[:field_lcp_ms]).to eq(3_120)
    expect(attributi[:field_inp_ms]).to eq(184)
    expect(attributi[:field_ttfb_ms]).to eq(910)
    expect(attributi[:field_overall_category]).to eq("AVERAGE")
  end

  # Seconda trappola: il CLS di campo arriva come intero moltiplicato per cento, perché il campo che
  # lo trasporta è dichiarato int32. Senza la divisione, un sito ottimo (0.08) si leggerebbe 8 —
  # ottanta volte oltre la soglia dello "scarso".
  it "riporta il CLS di campo alla sua scala: non è un intero" do
    expect(attributi[:field_cls]).to eq(0.08)
  end

  it "conserva le tre fasce per metrica, che sono la prova sotto il percentile" do
    fasce = attributi[:field_distributions]

    expect(fasce.keys).to include("LARGEST_CONTENTFUL_PAINT_MS", "CUMULATIVE_LAYOUT_SHIFT_SCORE")
    expect(fasce["LARGEST_CONTENTFUL_PAINT_MS"].sum { |f| f["proportion"] }).to be_within(0.01).of(1.0)
  end

  describe "quando Google non ha dati su questa pagina" do
    it "usa quelli dell'origine e lo DICHIARA" do
      risposta = fixture("pagespeed_success")
      risposta["loadingExperience"] = { "id" => "https://acme.example/", "metrics" => {} }
      risposta["originLoadingExperience"] = {
        "id" => "https://acme.example", "origin_fallback" => true, "overall_category" => "SLOW",
        "metrics" => { "LARGEST_CONTENTFUL_PAINT_MS" => { "percentile" => 5000 } }
      }

      esito = described_class.call(risposta)

      expect(esito[:field_origin_fallback]).to be(true)
      expect(esito[:field_lcp_ms]).to eq(5_000)
    end
  end

  # Il giro è già costato mezzo minuto a una macchina di Google: buttarlo perché una chiave non c'era
  # sarebbe uno spreco oltre che un guasto. Una misura in meno, mai un'eccezione.
  describe "una risposta a cui manca qualcosa" do
    it "non solleva mai: produce le misure che ci sono" do
      expect { described_class.call({}) }.not_to raise_error
      expect { described_class.call(nil) }.not_to raise_error
      expect(described_class.call({ "lighthouseResult" => "non un hash" })).to include(final_url: nil)
    end

    it "una chiave di campo che non conosciamo viene ignorata, non fa fallire il giro" do
      risposta = fixture("pagespeed_success")
      risposta["loadingExperience"]["metrics"]["METRICA_NUOVA_DI_GOOGLE"] = { "percentile" => 42 }

      expect { described_class.call(risposta) }.not_to raise_error
    end
  end
end
