# frozen_string_literal: true

require "rails_helper"

# CYRA-693 — la convenzione dice: descrizione di una voce max 300 caratteri (lead-in e link in coda
# esclusi), ma 33 voci su 71 la sforavano e nessun controllo la faceva rispettare. Questo gate vale
# per le voci NUOVE: lo storico fino alla versione qui sotto resta com'è (accorciarlo riscriverebbe
# comunicazioni già pubblicate), e la pagina lo rende ripiegato.
RSpec.describe "CHANGELOG — lunghezza delle voci" do
  GRANDFATHERED_UP_TO = Gem::Version.new("0.134.2")
  LIMIT = 300

  # La misura della convenzione: via il lead-in in grassetto, via i link markdown in coda
  # (guida inclusa), conta il resto.
  def measured_length(item)
    text = item.sub(/\A\*\*.+?\*\*:?\s*/, "")
    text = text.sub(/\s*\(?\[[^\]]+\]\([^)]+\)\)?\.?\s*\z/, "") while text.match?(/\[[^\]]+\]\([^)]+\)\)?\.?\s*\z/)
    text.strip.length
  end

  it "ogni voce successiva allo storico congelato sta nei 300 caratteri" do
    releases = Changelog::Parse.call(Rails.root.join("CHANGELOG.md").read)
    offending = releases.select { |release| Gem::Version.new(release.version) > GRANDFATHERED_UP_TO }
                        .flat_map do |release|
      release.sections.flat_map { |section| section[:items] }
             .select { |item| measured_length(item) > LIMIT }
             .map { |item| "[#{release.version}] #{item[0, 80]}… (#{measured_length(item)} caratteri)" }
    end

    expect(offending).to be_empty, "Voci oltre i #{LIMIT} caratteri (togli il racconto, non comprimere le parole):\n#{offending.join("\n")}"
  end
end
