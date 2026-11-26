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

  # CYRA-1150 — a bulk action that can be undone puts Undo on its notice, for 10 seconds.
  it "puts Undo on the notice of an undoable action and keeps it 10 seconds" do
    flash[:notice] = "3 gruppi aggiornati."
    flash[:undo] = "0b6f2c1e-0000-4000-8000-000000000001"

    render partial: "shared/flash"

    html = Capybara.string(rendered)
    expect(html).to have_css("[data-test='flash-notice'][data-ui--alert-duration-value='10000']")
    expect(html).to have_css("[data-test='flash-notice'] form[action='/member/undo/0b6f2c1e-0000-4000-8000-000000000001']")
    expect(html).to have_css("[data-test='flash-notice'] [data-test='flash-undo-button']")
    # The undo id is not a message: it never becomes a toast of its own.
    expect(html).to have_no_css("[data-test='flash-undo']")
  end

  it "shows today's toast, without Undo, for an action that cannot be undone" do
    flash[:notice] = "5 card approvate."

    render partial: "shared/flash"

    html = Capybara.string(rendered)
    expect(html).to have_no_css("[data-test='flash-undo-button']")
    expect(html).to have_no_css("[data-ui--alert-duration-value]")
  end

  it "tiene il contenitore nel DOM anche senza messaggi" do
    render partial: "shared/flash"

    # Se sparisse, il morph rimuoverebbe lui e con lui i toast dentro, permanent o no.
    expect(rendered).to include('data-test="flash-container"')
  end
end
