# frozen_string_literal: true

require "rails_helper"

# Il bundle vendorizzato del player replay deve contenere il MOTORE di replay, non solo il guscio
# Svelte. Il dist pubblicato di rrweb-player 2.1.0 (e il bundle jspm derivato) era monco: nessun
# Replayer dentro, riferimenti sostituiti con `(void 0)` — il player montava un riquadro vuoto
# senza iframe, senza controller e senza alcun errore in console. Questi spec fissano le stringhe
# che esistono solo nel motore inlined (@rrweb/replay): una ri-vendorizzazione monca torna rossa
# qui, non in produzione a schermo bianco.
RSpec.describe "vendor/javascript/rrweb-player.js — bundle completo" do
  let(:bundle) { Rails.root.join("vendor/javascript/rrweb-player.js").read }

  it "contiene il motore di replay (wrapper dell'iframe ricostruito)" do
    # `replayer-wrapper` è la classe che @rrweb/replay assegna al contenitore dell'iframe:
    # esiste solo se il motore è dentro il bundle.
    expect(bundle).to include("replayer-wrapper")
  end

  it "contiene la barra dei controlli del player" do
    expect(bundle).to include("rr-controller")
  end

  it "non contiene riferimenti al replayer sostituiti con void 0 (artefatto jspm monco)" do
    expect(bundle).not_to include("(void 0).getMirror")
  end
end
