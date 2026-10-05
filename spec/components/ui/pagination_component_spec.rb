# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::PaginationComponent, type: :component do
  def result(page:, total:, per: 25, total_pages: nil)
    tp = total_pages || (total.zero? ? 1 : (total.to_f / per).ceil)
    Pagination::Result.new(records: [], page: page, per: per, total: total, total_pages: tp)
  end

  # DESIGN.md C12: "0–0 of 0" under an empty list says nothing the empty page does not already say.
  it "renders nothing when there are no results" do
    render_inline(described_class.new(pagination: result(page: 1, total: 0)))
    expect(page).to have_no_css("[data-test='pagination-summary']")
    expect(page).to have_no_text("0–0 of 0")
  end

  it "shows from–to of total on a single page" do
    render_inline(described_class.new(pagination: result(page: 1, total: 3)))
    expect(page).to have_text("1–3 of 3")
  end

  it "una sola pagina: nessun controllo prev/next" do
    render_inline(described_class.new(pagination: result(page: 1, total: 10)))

    expect(page).to have_text("1–10 of 10")
    expect(page).to have_no_css("[data-test='pagination-prev']")
    expect(page).to have_no_css("[data-test='pagination-next']")
  end

  it "prima pagina di molte: prev disabilitato, next attivo, corrente evidenziata, ultima + ellissi" do
    render_inline(described_class.new(pagination: result(page: 1, total: 130))) # 6 pagine

    expect(page).to have_css("span.cursor-not-allowed", count: 1) # solo prev disabilitato
    expect(page).to have_css("[data-test='pagination-next']")
    expect(page).to have_css("span[aria-current='page']", text: "1")
    expect(page).to have_link("2")
    expect(page).to have_link("6")
    expect(page).to have_text("…")
  end

  it "ultima pagina: next disabilitato, prev attivo, corrente evidenziata" do
    render_inline(described_class.new(pagination: result(page: 6, total: 130)))

    expect(page).to have_css("[data-test='pagination-prev']")
    expect(page).to have_css("span.cursor-not-allowed", count: 1) # solo next disabilitato
    expect(page).to have_css("span[aria-current='page']", text: "6")
  end

  it "pagina centrale: prev e next attivi, prima/ultima + ellissi su entrambi i lati" do
    render_inline(described_class.new(pagination: result(page: 5, total: 250))) # 10 pagine, finestra 3..7

    expect(page).to have_css("[data-test='pagination-prev']")
    expect(page).to have_css("[data-test='pagination-next']")
    expect(page).to have_css("span[aria-current='page']", text: "5")
    expect(page).to have_link("1") # prima
    expect(page).to have_link("10") # ultima
    expect(page).to have_no_css("span.cursor-not-allowed") # nessun controllo disabilitato
  end

  it "i link pagina cambiano solo page" do
    render_inline(described_class.new(pagination: result(page: 1, total: 130)))
    expect(page).to have_link("2", href: /page=2/)
  end

  # CYRA-568 — «1–100 di 4031» sotto una lista che in cima diceva «4.031»: lo stesso numero scritto
  # in due modi nella stessa schermata. Il piede è il posto da cui passano TUTTE le liste.
  it "scrive le migliaia come le scrive la lingua" do
    I18n.with_locale(:it) do
      render_inline(described_class.new(pagination: result(page: 1, total: 4031, per: 100)))
      expect(page).to have_text("1–100 di 4.031")
    end
  end

  it "in inglese resta il formato inglese" do
    render_inline(described_class.new(pagination: result(page: 1, total: 4031, per: 100)))
    expect(page).to have_text("1–100 of 4,031")
  end

  # CYRA-839 — sul telefono riepilogo, scelta righe e pulsanti stavano su una riga sola e il
  # pulsante «Successivo» finiva fuori dallo schermo. Sotto `sm` il piede si impila: riepilogo e
  # scelta righe sopra, pulsanti sotto, ciascun gruppo libero di andare a capo. Da `sm` in su
  # torna la riga unica con i pulsanti a destra.
  describe "disposizione adattiva (CYRA-839)" do
    it "sotto sm impila i due gruppi, da sm li rimette su una riga" do
      render_inline(described_class.new(pagination: result(page: 1, total: 130), test_id: "things-pagination"))

      expect(page).to have_css("div[data-test='things-pagination'].flex-col.sm\\:flex-row.sm\\:justify-between")
    end

    it "riepilogo e scelta righe stanno in un gruppo che va a capo" do
      render_inline(described_class.new(pagination: result(page: 1, total: 130)))

      expect(page).to have_css("[data-test='pagination-summary'].flex-wrap [data-test='pagination-per']")
      expect(page).to have_css("[data-test='pagination-summary']", text: "1–25 of 130")
    end

    it "i pulsanti stanno in un gruppo che va a capo, con tutte le azioni" do
      render_inline(described_class.new(pagination: result(page: 5, total: 250)))

      expect(page).to have_css("[data-test='pagination-controls'].flex-wrap [data-test='pagination-prev']")
      expect(page).to have_css("[data-test='pagination-controls'] [data-test='pagination-next']")
      expect(page).to have_css("[data-test='pagination-controls'] span[aria-current='page']", text: "5")
    end

    it "i puntini di sospensione si vedono solo da sm" do
      render_inline(described_class.new(pagination: result(page: 5, total: 250)))

      expect(page).to have_css("[data-test='pagination-controls'] span.hidden.sm\\:inline", text: "…", count: 2)
    end

    it "con una sola pagina il gruppo dei pulsanti non c'è" do
      render_inline(described_class.new(pagination: result(page: 1, total: 10)))

      expect(page).to have_css("[data-test='pagination-summary']", text: "1–10 of 10")
      expect(page).to have_no_css("[data-test='pagination-controls']")
    end
  end

  it "applica il test_id al footer" do
    render_inline(described_class.new(pagination: result(page: 1, total: 10), test_id: "things-pagination"))
    expect(page).to have_css("div[data-test='things-pagination'].border-t")
  end

  # CYRA-924 — T10: the footer closes the panel with the legend and the pages on one row.
  it "puts the legend on the footer row, before the summary" do
    render_inline(described_class.new(pagination: result(page: 1, total: 3))) do |footer|
      footer.with_legend { "<span data-test='legend'>Shared</span>".html_safe }
    end
    expect(page).to have_css("[data-test='pagination-summary'] [data-test='legend'] + span", text: "1")
  end
end
