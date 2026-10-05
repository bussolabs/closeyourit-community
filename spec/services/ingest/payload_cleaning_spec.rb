# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — la pulizia dei byte nulli dal payload grezzo, condivisa da Errors/Metrics/Logs/Analytics.
# Postgres rifiuta il byte nullo dentro text e jsonb: se sfugge, l'evento non si salva e l'ingest
# perde il dato senza che il client se ne accorga. Il byte si scrive `0.chr`, mai letterale: un
# carattere invisibile dentro un file di prova è una prova che nessuno può più leggere.
RSpec.describe Ingest::PayloadCleaning, type: :service do
  let(:cleaner) { Class.new { include Ingest::PayloadCleaning }.new }
  let(:nullo) { 0.chr }

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

  it "conserva le chiavi: si ripuliscono i valori, non i nomi dei campi" do
    expect(cleaner.deep_clean({ "chiave" => "v#{nullo}" }).keys).to eq([ "chiave" ])
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
