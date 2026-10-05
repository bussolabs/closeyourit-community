# frozen_string_literal: true

require "rails_helper"

# I toast vivono anche sulle pagine che si ri-fetchano da sole (turbo_refreshes_with method: :morph).
# Lì il morph li cancellava dopo un paio di secondi, prima che si leggessero: l'azione appena lanciata
# sembrava non aver prodotto niente. Le due proprietà che lo impediscono sono verificate qui.
RSpec.describe "shared/_flash", type: :view do
  it "marca ogni toast come permanente, così il morph non lo cancella" do
    flash[:notice] = "Azione accodata."

    render partial: "shared/flash"

    expect(rendered).to include('data-turbo-permanent="true"')
    expect(rendered).to include('data-test="flash-notice"')
  end

  it "dà al toast un id stabile derivato dal contenuto" do
    flash[:notice] = "Azione accodata."

    render partial: "shared/flash"
    first = rendered.dup

    # Un id che cambiasse a ogni render farebbe rientrare il toast come nuovo a ogni morph.
    expect(first).to include("flash-notice-#{Digest::MD5.hexdigest('Azione accodata.')}")
  end

  it "tiene il contenitore nel DOM anche senza messaggi" do
    render partial: "shared/flash"

    # Se sparisse, il morph rimuoverebbe lui e con lui i toast dentro, permanent o no.
    expect(rendered).to include('data-test="flash-container"')
  end
end
