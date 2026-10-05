# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::EmbeddingText do
  let(:idea) do
    build(:idea, title: "Esportare i report in PDF", problem: "I clienti chiedono il PDF",
                 solution: "Un pulsante Esporta sulla lista")
  end

  it "compone il testo canonico con etichette fisse (titolo, problema, soluzione)" do
    text = described_class.call(idea: idea)

    expect(text).to eq(
      "Titolo: Esportare i report in PDF\n" \
      "Problema: I clienti chiedono il PDF\n" \
      "Soluzione: Un pulsante Esporta sulla lista"
    )
  end

  it "omette la soluzione quando è vuota (idea senza proposta di soluzione)" do
    idea.solution = ""

    expect(described_class.call(idea: idea)).to eq(
      "Titolo: Esportare i report in PDF\nProblema: I clienti chiedono il PDF"
    )
  end

  it "le etichette NON dipendono dalla lingua dell'utente (vettore locale-stabile)" do
    italiano = described_class.call(idea: idea)
    inglese = I18n.with_locale(:en) { described_class.call(idea: idea) }

    expect(inglese).to eq(italiano)
  end

  it "il checksum cambia col testo e include la versione del modello" do
    first = described_class.checksum(idea: idea)
    idea.title = "Altro titolo"

    expect(described_class.checksum(idea: idea)).not_to eq(first)
    expect(first).to eq(
      Digest::SHA256.hexdigest("#{Ai::Constants::EMBEDDING_VERSION}\nTitolo: Esportare i report in PDF\n" \
                               "Problema: I clienti chiedono il PDF\nSoluzione: Un pulsante Esporta sulla lista")
    )
  end

  it "le colonne sorvegliate sono quelle che compongono il testo" do
    expect(described_class::WATCHED_COLUMNS).to eq(%w[title problem solution])
  end
end
