# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::PlainLanguageCheck do
  def verdict(text) = described_class.call(text: text)

  it "considera semplice un testo breve e piano" do
    v = verdict("Questa pagina spiega come accedere. Inserisci la mail e la parola d'ordine. Poi premi entra.")
    expect(v).to be_simple
    expect(v).not_to be_complex
    expect(v.reasons).to be_empty
  end

  it "segnala i blocchi di codice" do
    v = verdict("Esempio d'uso:\n```ruby\nKnowledge::Page.all\n```")
    expect(v).to be_complex
    expect(v.reasons).to include(:code_block)
  end

  it "segnala le frasi troppo lunghe" do
    long = "#{([ 'parola' ] * 40).join(' ')}."
    expect(verdict(long).reasons).to include(:long_sentences)
  end

  it "segnala la densità di gergo tecnico" do
    v = verdict("Il middleware espone un endpoint webhook per il deploy del backend.")
    expect(v.reasons).to include(:jargon)
  end

  it "non è mai bloccante: testo vuoto è semplice, non solleva mai" do
    expect(verdict("")).to be_simple
    expect(verdict(nil)).to be_simple
  end
end
