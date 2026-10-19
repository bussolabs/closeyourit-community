# frozen_string_literal: true

require "rails_helper"

# CYRA-1081 — API and CLI errors reach every install in English, whatever the UI language.
#
# `render_error` answers machines only (JSON envelope), and a fresh self-hosted install speaks
# English: a fixed Italian sentence there greeted the first stranger who sent an event with a wrong
# DSN. Clients branch on the code, so the text is for the human reading the terminal.
RSpec.describe "API error messages language (CYRA-1081)" do
  # Italian function words and the stems of the messages translated in CYRA-1081: all 65 match,
  # none of their English versions does.
  ITALIAN_MARKERS = /
    [àèéìòù]
    | \b(?:non|di|del|della|dello|dei|degli|delle|nel|nella|per|il|lo|la|gli|le|un|una|uno|o|e|con
         |da|al|alla|sul|solo|prima|ancora|nessun[oa]?)\b
    | mancant|troppo|revocat|scadut|malformat|inesistent|fallit|\bvalid[oa]\b|trovat|negat|consentit
    | obbligatori|richiest|leggibil|corrispondent|ammess|collegabil|dichiarat|appartenent|agganciat
    | pinnat|pericolos|sospes|zione\b
  /ix

  # Any first argument (a literal code or a constant), then the literal message.
  FIXED_MESSAGE = /render_error\(\s*[^,()]+,\s*"([^"]+)"/m

  it "recognizes the Italian messages it replaced" do
    replaced = [ "Host revocato", "Evento malformato", "Secret inesistente", "Validazione fallita",
                 "Token CLI scaduto: esegui di nuovo l'accesso", "Organizzazione sospesa" ]

    expect(replaced.reject { |message| message.match?(ITALIAN_MARKERS) }).to be_empty
  end

  it "keeps every fixed render_error message in English" do
    italian = Rails.root.glob("app/controllers/**/*.rb").flat_map do |path|
      path.read.scan(FIXED_MESSAGE).flatten.grep(ITALIAN_MARKERS)
          .map { |message| "#{path.relative_path_from(Rails.root)}: #{message}" }
    end

    expect(italian).to be_empty, "Italian API error messages:\n#{italian.join("\n")}"
  end
end
