# frozen_string_literal: true

require "rails_helper"

# CYRA-432 — La spiegazione breve accanto al titolo si legge PER INTERO. Il pannello del tooltip ha
# due posizionamenti sovrapposti: il fallback CSS (classi placement, che lo centrano sul pallino con
# una traslazione del 50% della propria larghezza) e il calcolo in JS, che deve annullare il primo e
# tenere il pannello dentro lo schermo. Se l'annullamento non funziona il pannello finisce spostato
# di mezza larghezza a sinistra: su uno schermo stretto esce dal bordo e la frase si legge tagliata.
RSpec.describe "Ui::TooltipComponent — il pannello resta dentro lo schermo", :js, type: :system do
  let(:org) { create(:organization) }
  let(:owner) { create(:account, locale: "it") }

  # Il pannello è largo quanto il testo fino a un massimo dato dal foglio di stile compilato: senza
  # quel foglio la misura non dice niente sul difetto. Il build CSS non fa parte del setup dei test,
  # quindi qui si salta invece di diventare rossi per il motivo sbagliato.
  before do
    css = Rails.root.join("app/assets/builds/tailwind.css")
    skip "CSS Tailwind non compilato (bin/rails tailwindcss:build)" unless css.exist? && css.size.positive?

    create(:membership, account: owner, organization: org, role: :owner)
    create(:project, organization: org)
    sign_in_as(owner)
  end

  # CYRA-883 — member headers no longer carry the info bubble; the ticket form still does.
  def open_title_tooltip
    find("[data-test='help-scenarios'] button").hover
    expect(page).to have_css("[data-test='help-scenarios'] span[role='tooltip']", visible: :all, wait: 4)
  end

  def panel_geometry
    page.evaluate_script(<<~JS)
      (() => {
        const p = document.querySelector("[data-test='help-scenarios'] span[role='tooltip']");
        const r = p.getBoundingClientRect();
        return { left: r.left, right: r.right, top: r.top, bottom: r.bottom,
                 clippedX: p.scrollWidth - p.clientWidth, clippedY: p.scrollHeight - p.clientHeight,
                 vw: document.documentElement.clientWidth, vh: document.documentElement.clientHeight,
                 translate: getComputedStyle(p).translate };
      })()
    JS
  end

  it "on a narrow screen the ticket form hint is not cut off at the edge" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit new_member_ticket_path
    open_title_tooltip

    g = panel_geometry

    expect(g["left"]).to be >= 0, "the panel leaves the screen on the left (left #{g['left']})"
    expect(g["right"]).to be <= g["vw"]
    expect(g["top"]).to be >= 0
    expect(g["bottom"]).to be <= g["vh"]
    expect(g["clippedX"]).to be <= 0
    expect(g["clippedY"]).to be <= 0
  end

  it "il calcolo in JS annulla la traslazione del fallback CSS" do
    visit new_member_ticket_path
    open_title_tooltip

    expect(panel_geometry["translate"]).to eq("none")
  end
end
