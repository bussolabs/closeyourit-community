# frozen_string_literal: true

require "rails_helper"

# I valori dei segreti entrano nei controller del vault (progetto, condiviso, personale — canale web e
# CLI) sotto tre soli nomi di parametro: `value` (secret singolo), `values` (matrice nome×ambiente del
# form web) e `variables` (import in blocco da riga di comando). La lista `filter_parameters` fa match
# per SOTTOSTRINGA sul nome: finché nessuna voce compare in questi tre nomi, il valore in chiaro finisce
# nei log di Rails a ogni salvataggio, e chi legge i log raccoglie le credenziali man mano che vengono
# ruotate — senza alcun permesso sul vault e senza comparire in nessun audit (CYRA-203).
#
# Questa spec costruisce il filtro ESATTAMENTE come fa il logging di Rails (dall'array di config) e
# blocca la regressione su tutti e tre i nomi.
RSpec.describe "Filtro dei parametri sensibili nei log" do
  subject(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  it "maschera il valore singolo `value` (create web e CLI dei tre vault)" do
    expect(filter.filter("value" => "s3cr3t")).to eq("value" => "[FILTERED]")
  end

  it "maschera la matrice `values` (riga della matrice nome×ambiente del canale web)" do
    filtered = filter.filter("values" => { "42" => "s3cr3t", "43" => "altro-s3cr3t" })

    expect(filtered["values"]).to eq("[FILTERED]")
    expect(filtered.inspect).not_to include("s3cr3t")
  end

  it "maschera l'import in blocco `variables`: nemmeno uno dei venti valori resta in chiaro" do
    entries = Array.new(20) { |i| { "name" => "VAR_#{i}", "value" => "s3cr3t-#{i}" } }
    filtered = filter.filter("variables" => entries)

    expect(filtered["variables"]).to eq("[FILTERED]")
    expect(filtered.inspect).not_to include("s3cr3t")
  end
end
