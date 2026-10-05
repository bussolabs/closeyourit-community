# frozen_string_literal: true

require "rails_helper"

# Ogni cambio di valore lascia dietro di sé una versione immutabile: è quello che rende possibile
# tornare indietro. La numerazione cresce sempre e per variabile — due variabili diverse non si
# scambiano i numeri, e una versione cancellata non fa ripartire il conto da capo.
RSpec.describe Secrets::Personal::Versions::Snapshot do
  it "crea la prima versione col valore corrente della variabile" do
    variable = create(:personal_secret_variable, value: "v1")

    version = described_class.call(variable:)

    expect(version.number).to eq(1)
    expect(version.value).to eq("v1")
    expect(version.variable).to eq(variable)
  end

  it "le versioni successive salgono di uno" do
    variable = create(:personal_secret_variable, value: "v1")
    described_class.call(variable:)
    variable.update!(value: "v2")

    expect(described_class.call(variable:)).to have_attributes(number: 2, value: "v2")
  end

  it "il numero è per variabile: due variabili partono entrambe da uno" do
    account = create(:account)
    organization = create(:organization)
    prima = create(:personal_secret_variable, account:, organization:)
    seconda = create(:personal_secret_variable, account:, organization:)

    expect(described_class.call(variable: prima).number).to eq(1)
    expect(described_class.call(variable: seconda).number).to eq(1)
  end

  # Il numero segue il MASSIMO già assegnato, non quante versioni ci sono: la cronologia di una
  # variabile non nasce sempre da qui (un ripristino ne scrive di sue) e due versioni con lo stesso
  # numero renderebbero ambiguo a cosa si torna indietro.
  it "riparte dal numero più alto già assegnato, non dal conteggio" do
    variable = create(:personal_secret_variable, value: "corrente")
    create(:personal_secret_version, variable:, number: 7)

    expect(described_class.call(variable:).number).to eq(8)
  end

  it "il valore fotografato è quello della variabile in quel momento, non quello di prima" do
    variable = create(:personal_secret_variable, value: "vecchio")
    described_class.call(variable:)
    variable.update!(value: "nuovo")

    expect(variable.versions.order(:number).map(&:value)).to eq(%w[vecchio])
    expect(described_class.call(variable:).value).to eq("nuovo")
  end
end
