# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Review::Rules do
  it "descrive esattamente i formati dell'enum, nello stesso ordine" do
    expect(described_class.formats_in_text).to eq(Knowledge::Constants::REVIEW_FORMATS)
  end

  it "il prompt di sistema porta le regole, il formato della risposta e la regola ortografica" do
    prompt = described_class.system_prompt
    expect(prompt).to include("## Regole comuni")
    expect(prompt).to include("## Come rispondere")
    expect(prompt).to include(Text::ItalianOrthography::PROMPT_RULE.strip)
  end

  it "nomina ogni codice di regola che il pre-check può emettere" do
    Knowledge::Review::Precheck::PART # carica la classe
    %w[K01 K02 K07 K08 K10 K11 K12 K14 P05 A01].each { |code| expect(described_class.text).to include(code) }
  end

  # CYAU-200 — il rifiuto deve dire anche DOVE: il passaggio della pagina che lo motiva.
  it "chiede al modello il passaggio citato, e di lasciarlo vuoto quando manca qualcosa" do
    expect(described_class::OUTPUT_RULES).to include("quote")
    expect(described_class::OUTPUT_RULES).to include("vuota")
  end

  # La copia umana vive nel repo della knowledge base: quando è sul disco, le due devono coincidere
  # parola per parola, o chi scrive a mano segue regole diverse da quelle che giudicano.
  human_copy = Pathname.new(File.expand_path("~/Lavoro/Github/Personale/knowledge-base/global/knowledge-formats.md"))
  it "coincide con knowledge-base/global/knowledge-formats.md", if: human_copy.exist? do
    expect(human_copy.read).to eq(described_class.text)
  end
end
