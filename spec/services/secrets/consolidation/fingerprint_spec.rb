# frozen_string_literal: true

require "rails_helper"

# L'impronta è ciò che permette di dire «questi due segreti sono lo stesso valore» senza decifrarli e
# senza tenerli in chiaro da nessuna parte. Deve quindi essere STABILE (stesso valore, stessa
# impronta, sempre), CIECA (dall'impronta non si torna al valore) e SILENZIOSA sui valori troppo
# corti, che sono quasi sempre interruttori (`1`, `true`, `debug`) e non segreti condivisi.
RSpec.describe Secrets::Consolidation::Fingerprint do
  it "dà la stessa impronta allo stesso valore, ogni volta" do
    expect(described_class.for("password-lunghissima")).to eq(described_class.for("password-lunghissima"))
  end

  it "dà impronte diverse a valori diversi" do
    expect(described_class.for("password-lunghissima")).not_to eq(described_class.for("password-lunghissim@"))
  end

  it "non contiene il valore in chiaro" do
    expect(described_class.for("password-lunghissima")).not_to include("password")
  end

  it "non è il semplice SHA256 del valore: senza la chiave un dizionario non la indovina" do
    expect(described_class.for("password-lunghissima")).not_to eq(Digest::SHA256.hexdigest("password-lunghissima"))
  end

  # Sotto la soglia non c'è impronta e quindi non c'è proposta: un `1` uguale in venti progetti non è
  # un segreto in comune da spostare, è rumore che coprirebbe le proposte vere.
  it "non impronta i valori più corti della soglia" do
    expect(described_class.for("1")).to be_nil
    expect(described_class.for("a" * (described_class::MIN_LENGTH - 1))).to be_nil
  end

  it "impronta i valori lunghi esattamente quanto la soglia" do
    expect(described_class.for("a" * described_class::MIN_LENGTH)).to be_present
  end

  # Vuoto e assente non sono la stessa cosa altrove nel vault (una stringa vuota è un valore
  # legittimo), ma nessuno dei due è un valore da consolidare.
  it "non impronta il valore assente né quello vuoto" do
    expect(described_class.for(nil)).to be_nil
    expect(described_class.for("")).to be_nil
  end

  it "distingue valori che differiscono solo per spazi o maiuscole" do
    expect(described_class.for("valore-segreto ")).not_to eq(described_class.for("valore-segreto"))
    expect(described_class.for("Valore-Segreto")).not_to eq(described_class.for("valore-segreto"))
  end
end
