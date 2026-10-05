# frozen_string_literal: true

require "rails_helper"

# La condizione di completamento di CYRA-594. Senza una prova, «non c'è più» è un'opinione: un
# riferimento rimasto in un locale, in una factory o in un manifest non fa fallire nessun altro
# test, e si scopre quando qualcuno apre la pagina delle integrazioni e trova un servizio che non
# esiste, o quando un deploy chiede al vault un segreto che nessuno legge più.
#
# Si cercano i riferimenti ATTIVI — costanti, simboli, chiavi di configurazione — non la parola.
# I commenti che raccontano perché una scelta è cambiata restano, e devono restare: sono la memoria
# di come ci si è arrivati, e cancellarli per far passare una prova è il contrario del punto.
RSpec.describe "Proxanything non è più nel prodotto" do
  # `Ai::Proxanything::…`, `:proxanything`, `"proxanything"`, `PROXANYTHING_API_KEY`, `$PROXANYTHING…`
  ACTIVE_REFERENCE = /Ai::Proxanything|[:"']proxanything["']?\s*(?:=>|:|\))|PROXANYTHING_[A-Z_]+/
  ROOTS = %w[app config lib .kamal spec].freeze

  it "non compare come costante, simbolo o variabile in nessun file sorgente, manifest o traduzione" do
    hits = ROOTS.flat_map do |root|
      Dir.glob(Rails.root.join(root, "**/*")).select do |path|
        next false unless File.file?(path)
        next false if path.end_with?("no_proxanything_spec.rb")

        # Le fixture binarie (immagini di prova) non sono testo: senza `scrub` il confronto solleva
        # `invalid byte sequence in UTF-8` sul primo PNG che incontra.
        File.binread(path).force_encoding("UTF-8").scrub("").match?(ACTIVE_REFERENCE)
      end
    end

    expect(hits).to be_empty, "riferimenti attivi rimasti:\n#{hits.join("\n")}"
  end

  it "il registro delle integrazioni non lo conosce più" do
    expect(Integrations::Providers.known?("proxanything")).to be(false)
  end
end
