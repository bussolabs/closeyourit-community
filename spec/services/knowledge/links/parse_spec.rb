# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Links::Parse do
  def titles(text)
    described_class.call(text: text).map(&:title)
  end

  it "estrae un wikilink semplice" do
    refs = described_class.call(text: "Segue [[Deploy Kamal]].")
    expect(refs.map(&:title)).to eq([ "Deploy Kamal" ])
    expect(refs.map(&:anchor_text)).to eq([ "Deploy Kamal" ])
  end

  it "usa la label dopo la pipe come testo mostrato" do
    refs = described_class.call(text: "Vedi [[Deploy Kamal|la guida al deploy]].")
    expect(refs.first.title).to eq("Deploy Kamal")
    expect(refs.first.anchor_text).to eq("la guida al deploy")
  end

  it "estrae più wikilink nell'ordine di apparizione" do
    expect(titles("[[Uno]] poi [[Due]] infine [[Tre]]")).to eq(%w[Uno Due Tre])
  end

  it "deduplica i riferimenti allo stesso titolo, ignorando maiuscole e spazi" do
    expect(titles("[[Deploy Kamal]] e [[ deploy kamal ]] e [[DEPLOY KAMAL]]")).to eq([ "Deploy Kamal" ])
  end

  it "normalizza gli spazi ai bordi del titolo" do
    expect(titles("[[  Deploy Kamal  ]]")).to eq([ "Deploy Kamal" ])
  end

  it "ignora un wikilink dentro un blocco di codice recintato" do
    expect(titles("prima\n```\nscrivi [[Deploy Kamal]]\n```\n")).to be_empty
  end

  it "ignora un wikilink dentro un code span inline" do
    expect(titles("per collegare scrivi `[[Titolo pagina]]` nel testo")).to be_empty
  end

  it "estrae i wikilink fuori dal codice anche se ce ne sono dentro" do
    expect(titles("vedi [[Fuori]]\n```\n[[Dentro]]\n```\n")).to eq([ "Fuori" ])
  end

  it "ignora un titolo vuoto o di soli spazi" do
    expect(titles("[[]] e [[   ]]")).to be_empty
  end

  it "ignora le parentesi quadre singole" do
    expect(titles("un [link](http://esempio.test) e un [riferimento]")).to be_empty
  end

  it "non attraversa una fine riga" do
    expect(titles("[[Titolo\nspezzato]]")).to be_empty
  end

  it "tronca a MAX_LINKS riferimenti" do
    text = (1..(described_class::MAX_LINKS + 10)).map { |n| "[[Pagina #{n}]]" }.join(" ")
    expect(described_class.call(text: text).size).to eq(described_class::MAX_LINKS)
  end

  it "ritorna [] su testo vuoto o nil" do
    expect(described_class.call(text: "")).to eq([])
    expect(described_class.call(text: nil)).to eq([])
  end

  it "ignora una label vuota e ricade sul titolo" do
    refs = described_class.call(text: "[[Deploy Kamal|   ]]")
    expect(refs.first.anchor_text).to eq("Deploy Kamal")
  end
end
