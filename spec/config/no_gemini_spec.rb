# frozen_string_literal: true

require "rails_helper"

# CYRA-765: l'AI generativa la offre il sistema (server AI di casa). Gemini non deve rientrare dalla
# finestra: né come costante, né come endpoint, né come variabile d'ambiente.
#
# Si cercano i riferimenti ATTIVI — costanti, simboli, chiavi di configurazione — non la parola: i
# commenti che raccontano perché una scelta è cambiata restano, e devono restare.
RSpec.describe "Gemini non è più nel prodotto" do
  ACTIVE_GEMINI_REFERENCE = /Ai::Gemini|generativelanguage\.googleapis\.com|GOOGLE_GEMINI_[A-Z_]+|[:"']gemini["']?\s*(?:=>|:|\))/
  GEMINI_ROOTS = %w[app config lib .kamal spec].freeze
  # La spec della migration che cancella le credenziali deve nominare il provider per verificare che
  # siano sparite: è la prova della rimozione, non un residuo.
  GEMINI_ESENTI = %w[no_gemini_spec.rb drop_gemini_credentials_spec.rb].freeze

  it "non compare in nessun file sorgente, manifest, traduzione o spec" do
    hits = GEMINI_ROOTS.flat_map do |root|
      Dir.glob(Rails.root.join(root, "**/*")).select do |path|
        next false unless File.file?(path)
        next false if GEMINI_ESENTI.any? { |esente| path.end_with?(esente) }

        # Le fixture binarie non sono testo: senza `scrub` il confronto solleva
        # `invalid byte sequence in UTF-8` sul primo PNG che incontra.
        File.binread(path).force_encoding("UTF-8").scrub("").match?(ACTIVE_GEMINI_REFERENCE)
      end
    end

    expect(hits).to be_empty, "riferimenti attivi rimasti:\n#{hits.join("\n")}"
  end

  it "il registro delle integrazioni non lo conosce più" do
    expect(Integrations::Providers.known?("gemini")).to be(false)
  end
end
