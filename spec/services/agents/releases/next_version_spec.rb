# frozen_string_literal: true

require "rails_helper"

# CYRA-621 — la regola con cui il server sceglie il numero. Prima la sceglieva la macchina: le
# istruzioni le dicevano «guarda l'ultimo numero e le novità, poi decidi tu quale cifra cambiare», e
# nessuno controllava quella scelta né prima né dopo.
RSpec.describe Agents::Releases::NextVersion do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }

  def calcolo(tickets, tags)
    described_class.call(repository:, tickets:, client: versioni_uscite(tags))
  end

  def ticket(kind) = create(:ticket, organization:, project:, kind:)

  it "solo correzioni: cambia l'ultima cifra" do
    esito = calcolo([ ticket(:bug) ], %w[v1.4.2 v1.4.1])

    expect(esito.value).to eq(version: "v1.4.3", baseline_tag: "v1.4.2")
  end

  it "una novità: cambia la cifra di mezzo e azzera l'ultima" do
    esito = calcolo([ ticket(:story) ], %w[v1.4.2])

    expect(esito.value[:version]).to eq("v1.5.0")
  end

  # Fra sbagliare in su e sbagliare in giù, in su è l'errore che non nasconde una novità dentro una
  # correzione.
  it "correzioni MISCHIATE a una novità: vale la novità" do
    esito = calcolo([ ticket(:bug), ticket(:story) ], %w[v1.4.2])

    expect(esito.value[:version]).to eq("v1.5.0")
  end

  # Il confronto è fra NUMERI: in ordine alfabetico «v0.9.0» viene dopo «v0.10.0», e si ripartirebbe
  # da un numero già superato.
  it "prende il più alto, non l'ultimo in ordine alfabetico" do
    esito = calcolo([ ticket(:bug) ], %w[v0.9.0 v0.10.0 v0.8.7])

    expect(esito.value[:baseline_tag]).to eq("v0.10.0")
    expect(esito.value[:version]).to eq("v0.10.1")
  end

  # Le versioni di prova non sono versioni uscite: partire da una di quelle vorrebbe dire numerare
  # sopra qualcosa che non è mai andato a nessuno.
  it "ignora le versioni di prova e tutto ciò che non è un numero stabile" do
    esito = calcolo([ ticket(:bug) ], %w[v1.4.2 v1.5.0-beta.1 latest v1.5.0-rc1])

    expect(esito.value[:baseline_tag]).to eq("v1.4.2")
  end

  it "nessuna versione uscita: si parte dalla prima" do
    esito = calcolo([ ticket(:bug) ], [])

    expect(esito.value).to eq(version: "v0.1.0", baseline_tag: nil)
  end

  # La prima cifra non si cambia mai da sola: quello resta un salto che decide una persona, e
  # indovinarlo sarebbe annunciare una rottura che nessuno ha deciso.
  it "non alza mai la prima cifra da sola" do
    %i[bug story task epic].each do |kind|
      esito = calcolo([ ticket(kind) ], %w[v2.7.9])
      expect(esito.value[:version]).to start_with("v2."), kind.to_s
    end
  end

  it "legge i tag col numero dell'installazione GitHub, non con la chiave interna (CYRA-762)" do
    client = instance_double(Github::Client)
    allow(client).to receive(:tags).and_return([ "v0.1.0" ])

    described_class.call(repository:, tickets: [ ticket(:bug) ], client:)

    expect(client).to have_received(:tags).with(repository.installation.installation_id, repository.full_name)
  end

  # Senza sapere da dove si parte non si sceglie un numero: inventarne uno rischierebbe di riusare un
  # nome già uscito, che è il difetto peggiore che questo pezzo possa fare.
  it "se non riesce a leggere le versioni uscite non ne inventa una" do
    client = instance_double(Github::Client)
    allow(client).to receive(:tags).and_raise(Github::Client::Error.new("giù", code: "R502-GITHUB-001"))

    esito = described_class.call(repository:, tickets: [ ticket(:bug) ], client:)

    expect(esito.error.code).to eq("R409-WORKFLOW-008")
  end
end
