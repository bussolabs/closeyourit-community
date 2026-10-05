# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Links::Segments do
  # Invariante fondamentale: i segmenti ricomposti devono ridare il testo IDENTICO all'originale,
  # altrimenti Links::Render (che ricostruisce il markdown) corromperebbe il corpo della pagina.
  def roundtrip(text)
    described_class.call(text: text).map(&:text).join
  end

  def prose(text)
    described_class.call(text: text).reject(&:code).map(&:text).join
  end

  it "ritorna un unico segmento di prosa su testo senza codice" do
    segments = described_class.call(text: "Solo prosa, niente codice.")
    expect(segments.map(&:code)).to eq([ false ])
    expect(segments.first.text).to eq("Solo prosa, niente codice.")
  end

  it "ritorna [] su testo vuoto" do
    expect(described_class.call(text: "")).to eq([])
    expect(described_class.call(text: nil)).to eq([])
  end

  it "marca come codice un blocco recintato da backtick" do
    text = "prima\n```ruby\nputs :ciao\n```\ndopo\n"
    expect(prose(text)).to eq("prima\ndopo\n")
    expect(roundtrip(text)).to eq(text)
  end

  it "marca come codice un blocco recintato da tilde" do
    text = "prima\n~~~\nputs :ciao\n~~~\ndopo\n"
    expect(prose(text)).to eq("prima\ndopo\n")
    expect(roundtrip(text)).to eq(text)
  end

  it "tratta come codice fino alla fine una recinzione mai chiusa" do
    text = "prima\n```\nmai chiusa\n"
    expect(prose(text)).to eq("prima\n")
    expect(roundtrip(text)).to eq(text)
  end

  it "chiude solo su una recinzione dello stesso carattere" do
    text = "```\ncodice\n~~~\nancora codice\n```\nprosa\n"
    expect(prose(text)).to eq("prosa\n")
    expect(roundtrip(text)).to eq(text)
  end

  it "marca come codice un code span inline" do
    text = "usa `bin/rails console` per aprire"
    expect(prose(text)).to eq("usa  per aprire")
    expect(roundtrip(text)).to eq(text)
  end

  it "gestisce un code span con backtick multipli" do
    text = "scrivi ``dentro ` fuori`` e basta"
    expect(prose(text)).to eq("scrivi  e basta")
    expect(roundtrip(text)).to eq(text)
  end

  it "lascia in prosa un backtick spaiato" do
    text = "un backtick ` solo"
    expect(prose(text)).to eq(text)
  end

  it "gestisce blocchi recintati e code span nello stesso testo" do
    text = "usa `foo`\n```\nbar\n```\npoi `baz`\n"
    expect(prose(text)).to eq("usa \npoi \n")
    expect(roundtrip(text)).to eq(text)
  end

  it "preserva il testo originale anche senza newline finale" do
    text = "```\ncodice\n```"
    expect(roundtrip(text)).to eq(text)
  end
end
