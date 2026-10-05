# frozen_string_literal: true

require "rails_helper"

RSpec.describe Changelog::Parse do
  let(:text) do
    <<~MD
      # Changelog

      ## [Unreleased]

      ## [0.0.52] - 2026-07-01

      ### Added
      - **Revisore del ticket.** Prima riga della voce
        che prosegue su una seconda riga indentata.
      - **Notifica in revisione.** Corpo breve.

      ### Fixed
      - Bugfix semplice senza grassetto.

      ## [0.0.51] - 2026-06-30

      ### Changed
      - **Presenza ristretta.** Testo.
    MD
  end

  subject(:releases) { described_class.call(text) }

  it "restituisce una release per ogni versione, saltando Unreleased" do
    expect(releases.map(&:version)).to eq(%w[0.0.52 0.0.51])
  end

  it "estrae versione e data della prima release" do
    expect(releases.first).to have_attributes(version: "0.0.52", date: "2026-07-01")
  end

  it "espone la label con prefisso v" do
    expect(releases.first.label).to eq("v0.0.52")
  end

  it "raggruppa le voci per sezione mantenendo l'ordine" do
    sezioni = releases.first.sections
    expect(sezioni.map { |s| s[:label] }).to eq(%w[Added Fixed])
    expect(sezioni.first[:items].size).to eq(2)
    expect(sezioni.last[:items]).to eq([ "Bugfix semplice senza grassetto." ])
  end

  it "unisce le righe di continuazione indentate in un'unica voce" do
    prima_voce = releases.first.sections.first[:items].first
    expect(prima_voce).to eq(
      "**Revisore del ticket.** Prima riga della voce che prosegue su una seconda riga indentata."
    )
  end

  it "isola le sezioni della seconda release" do
    expect(releases.last.sections.map { |s| s[:label] }).to eq(%w[Changed])
  end

  it "restituisce un array vuoto su testo vuoto" do
    expect(described_class.call("")).to eq([])
  end

  it "ignora un CHANGELOG con la sola sezione Unreleased" do
    expect(described_class.call("# Changelog\n\n## [Unreleased]\n")).to eq([])
  end
end
