# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — la pulizia dei byte nulli dal payload grezzo, condivisa da Errors/Metrics/Logs/Analytics.
# Postgres rifiuta il byte nullo dentro text e jsonb: se sfugge, l'evento non si salva e l'ingest
# perde il dato senza che il client se ne accorga. Il byte si scrive `0.chr`, mai letterale: un
# carattere invisibile dentro un file di prova è una prova che nessuno può più leggere.
RSpec.describe Ingest::PayloadCleaning, type: :service do
  let(:cleaner) { Class.new { include Ingest::PayloadCleaning }.new }
  let(:nullo) { 0.chr }

  it "does not mutate nested dirty keys or values and remains idempotent" do
    original = { "nested#{nullo}" => [ { "k#{nullo}" => "v#{nullo}", "k" => "original", "k_2" => "reserved" } ] }
    snapshot = original.deep_dup
    cleaned = cleaner.deep_clean(original)
    expect(cleaned).to eq("nested" => [ { "k_3" => "v", "k" => "original", "k_2" => "reserved" } ])
    expect(original).to eq(snapshot)
    expect(cleaner.deep_clean(cleaned)).to eq(cleaned)
  end

  it "toglie il byte nullo da una stringa e lascia il resto intatto" do
    expect(cleaner.deep_clean("ciao#{nullo} mondo")).to eq("ciao mondo")
  end

  it "toglie tutte le occorrenze, non solo la prima" do
    expect(cleaner.deep_clean("a#{nullo}b#{nullo}c")).to eq("abc")
  end

  it "scende dentro gli hash annidati" do
    sporco = { "a" => { "b" => "x#{nullo}y" } }
    expect(cleaner.deep_clean(sporco)).to eq({ "a" => { "b" => "xy" } })
  end

  it "scende dentro gli array, anche di hash" do
    sporco = [ "a#{nullo}", { "k" => "b#{nullo}" } ]
    expect(cleaner.deep_clean(sporco)).to eq([ "a", { "k" => "b" } ])
  end

  it "conserva le chiavi pulite così come sono" do
    expect(cleaner.deep_clean({ "chiave" => "v#{nullo}" }).keys).to eq([ "chiave" ])
  end

  # CYRA-1218 — Postgres rifiuta il byte nullo anche nel NOME di un campo jsonb: un solo log con una
  # chiave sporca faceva cadere l'intero batch.
  describe "nomi dei campi" do
    it "toglie il byte nullo dal nome di un campo" do
      expect(cleaner.deep_clean({ "chi#{nullo}ave" => "v" })).to eq({ "chiave" => "v" })
    end

    it "toglie il byte nullo dai nomi annidati, anche dentro gli array" do
      sporco = { "a#{nullo}" => { "b#{nullo}" => [ { "c#{nullo}" => "x" } ] } }
      expect(cleaner.deep_clean(sporco)).to eq({ "a" => { "b" => [ { "c" => "x" } ] } })
    end

    it "con due nomi coincidenti tiene entrambi i valori, il pulito al suo nome" do
      pulito_prima = { "k" => "pulito", "k#{nullo}" => "sporco" }
      sporco_prima = { "k#{nullo}" => "sporco", "k" => "pulito" }

      [ pulito_prima, sporco_prima ].each do |sporco|
        expect(cleaner.deep_clean(sporco)).to eq({ "k" => "pulito", "k_2" => "sporco" })
      end
    end

    it "il numero aggiunto salta i nomi già occupati" do
      sporco = { "k#{nullo}" => "sporco", "k" => "pulito", "k_2" => "secondo" }
      expect(cleaner.deep_clean(sporco)).to eq({ "k" => "pulito", "k_2" => "secondo", "k_3" => "sporco" })
    end

    it "due nomi sporchi che coincidono restano distinti" do
      sporco = { "k#{nullo}" => "uno", "#{nullo}k" => "due" }
      expect(cleaner.deep_clean(sporco)).to eq({ "k" => "uno", "k_2" => "due" })
    end

    it "un nome riservato rinominato resta riconoscibile dall'oscuramento" do
      pulito = cleaner.deep_clean({ "token" => "a", "tok#{nullo}en" => "b" })
      expect(pulito.keys).to all(match(Ingest::PiiScrubbing::SENSITIVE_KEY))
    end

    it "lascia stare i nomi che non sono testo" do
      expect(cleaner.deep_clean({ simbolo: "v#{nullo}", 1 => "n" })).to eq({ simbolo: "v", 1 => "n" })
    end
  end

  it "lascia com'è ciò che non è testo (numeri, booleani, nil)" do
    expect(cleaner.deep_clean({ "n" => 42, "b" => true, "z" => nil }))
      .to eq({ "n" => 42, "b" => true, "z" => nil })
  end

  it "una stringa senza byte nulli non viene modificata" do
    expect(cleaner.deep_clean("tutto a posto")).to eq("tutto a posto")
  end

  it "non modifica l'oggetto ricevuto: torna una copia ripulita" do
    originale = { "a" => "x#{nullo}" }
    cleaner.deep_clean(originale)
    expect(originale["a"]).to eq("x#{nullo}")
  end
end
