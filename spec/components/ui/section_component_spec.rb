# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::SectionComponent, type: :component do
  it "rende superficie, intestazione col titolo e corpo" do
    render_inline(described_class.new(title: "Dettagli", test_id: "error-details")) { "corpo" }

    expect(page).to have_css("div.rounded-lg.border.border-stone-200.bg-white[data-test='error-details']")
    expect(page).to have_css("div.px-4.py-3.border-b.border-stone-200 > h2.font-display", text: "Dettagli")
    expect(page).to have_css("div.px-4.py-4", text: "corpo")
  end

  # La grafia dell'intestazione è quella che le pagine hanno già scritta a mano 191 volte: se il
  # componente ne emette una diversa, la pagina cambia aspetto mentre il ticket dice il contrario.
  it "scrive l'intestazione con la stessa grafia delle pagine" do
    render_inline(described_class.new(title: "Dettagli")) { "corpo" }

    expect(page.native.to_html).to include(
      '<div class="px-4 py-3 border-b border-stone-200 dark:border-zinc-800">' \
      '<h2 class="font-display text-[14px] font-semibold text-zinc-900 dark:text-zinc-100">Dettagli</h2></div>'
    )
  end

  it "mette le azioni accanto al titolo e allinea l'intestazione" do
    render_inline(described_class.new(title: "Grafico")) do |section|
      section.with_actions { "azione" }
      "corpo"
    end

    expect(page).to have_css("div.px-4.py-3.flex.items-center.justify-between.gap-3", text: "azione")
  end

  it "accetta un titolo composto al posto della stringa" do
    render_inline(described_class.new) do |section|
      section.with_title { "<svg data-icon='list-checks'></svg>Triage".html_safe }
      "corpo"
    end

    expect(page).to have_css("h2 svg[data-icon='list-checks']", visible: :all)
    expect(page).to have_css("h2", text: "Triage")
  end

  it "senza titolo e senza azioni non disegna l'intestazione" do
    render_inline(described_class.new(test_id: "nuda")) { "corpo" }

    expect(page).to have_no_css("div.border-b")
    expect(page).to have_css("div[data-test='nuda'] > div.px-4.py-4", text: "corpo")
  end

  # Le tabelle e gli elenchi divisi arrivano fino al bordo: un corpo con padding li staccherebbe
  # dalla cornice, che è esattamente ciò che oggi NON succede nelle pagine.
  it "lascia il corpo nudo quando il contenuto arriva al bordo" do
    render_inline(described_class.new(title: "Occorrenze", body_class: nil)) { "<table></table>".html_safe }

    expect(page).to have_no_css("div.px-4.py-4")
    expect(page).to have_css("div.rounded-lg > table")
  end

  # La sezione che segnala qualcosa da guardare ha una cornice ambra, bordo dell'intestazione
  # compreso: la tinta è una variante di codice, non una classe scritta a mano dal chiamante.
  it "accetta la tinta ambra e la porta anche sul bordo dell'intestazione" do
    render_inline(described_class.new(title: "Simili", tone: :amber, tag: :section, test_id: "simili")) { "corpo" }

    expect(page).to have_css("section.rounded-lg.border-amber-200.bg-amber-50\\/50[data-test='simili']")
    expect(page).to have_css("div.px-4.py-3.border-b.border-amber-100", text: "Simili")
  end

  it "rifiuta una tinta che non esiste" do
    expect { render_inline(described_class.new(title: "X", tone: :fucsia)) }.to raise_error(ArgumentError, /tone/)
  end

  it "unisce le classi del chiamante senza perdere le proprie" do
    render_inline(described_class.new(title: "X", class: "mt-4")) { "corpo" }

    expect(page).to have_css("div.rounded-lg.mt-4")
  end

  # La riga che spiega la base di quello che segue sta sotto il titolo, non dentro: un `<p>` dentro
  # un `<h2>` non è markup valido, e il titolo smetterebbe di leggersi come titolo.
  it "mette la riga di spiegazione sotto il titolo, come fratello" do
    render_inline(described_class.new(title: "Stesso messaggio")) do |section|
      section.with_subtitle { "<p class='mt-0.5'>Confronto esatto</p>".html_safe }
      "corpo"
    end

    expect(page).to have_css("div.border-b > h2", text: "Stesso messaggio")
    expect(page).to have_css("div.border-b > p", text: "Confronto esatto")
  end

  it "stringe titolo e spiegazione a sinistra quando ci sono anche le azioni" do
    render_inline(described_class.new(title: "Stesso messaggio")) do |section|
      section.with_subtitle { "<p>Confronto esatto</p>".html_safe }
      section.with_actions { "<button>ok</button>".html_safe }
      "corpo"
    end

    expect(page).to have_css("div.justify-between > div > h2", text: "Stesso messaggio")
    expect(page).to have_css("div.justify-between > div > p", text: "Confronto esatto")
    expect(page).to have_css("div.justify-between > button")
  end

  it "sceglie la grafia della riga d'intestazione fra quelle del design system" do
    render_inline(described_class.new(title: "Andamento", header_layout: :row)) do |section|
      section.with_actions { "azione" }
      "corpo"
    end

    expect(page).to have_css("div.px-4.py-3.flex.items-center.gap-2")
    expect(page).to have_no_css("div.justify-between")
  end

  it "rifiuta una grafia d'intestazione che non esiste" do
    expect { render_inline(described_class.new(title: "X", header_layout: :sparsa)) }
      .to raise_error(ArgumentError, /header_layout/)
  end

  it "sceglie la misura del titolo fra quelle del design system" do
    render_inline(described_class.new(title: "Dettagli", heading_size: :md)) { "corpo" }

    expect(page).to have_css("h2.font-display", text: "Dettagli")
    expect(page.native.to_html).to include('<h2 class="font-display text-[15px] font-semibold text-zinc-900 dark:text-zinc-100">')
  end

  it "rifiuta una misura del titolo che non esiste" do
    expect { render_inline(described_class.new(title: "X", heading_size: :gigante)) }
      .to raise_error(ArgumentError, /heading_size/)
  end

  it "abbassa l'intestazione quando il pannello sta accanto a una tabella" do
    render_inline(described_class.new(title: "Stessa richiesta", header_padding: :compact)) { "corpo" }

    expect(page).to have_css("div.px-4.py-2\\.5.border-b")
    expect(page).to have_no_css("div.py-3")
  end

  it "rifiuta un'altezza d'intestazione che non esiste" do
    expect { render_inline(described_class.new(title: "X", header_padding: :enorme)) }
      .to raise_error(ArgumentError, /header_padding/)
  end

  it "folds into a native details when collapsible, open by default" do
    render_inline(described_class.new(title: "About", collapsible: true, test_id: "about")) { "body" }

    expect(page).to have_css("details.group.rounded-lg.border[data-test='about'][open] > summary h2", text: "About")
    expect(page).to have_css("details > summary svg", visible: :all)
    expect(page).to have_css("details > div.px-4.py-4", text: "body")
  end

  it "starts closed when asked" do
    render_inline(described_class.new(title: "About", collapsible: true, collapsed: true)) { "body" }

    expect(page).to have_css("details:not([open]) > summary", text: "About")
  end

  it "stays a plain block when not collapsible" do
    render_inline(described_class.new(title: "About")) { "body" }

    expect(page).to have_no_css("details")
  end
end
