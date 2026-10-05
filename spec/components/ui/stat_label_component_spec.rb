# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::StatLabelComponent, type: :component do
  # DESIGN.md T12 — counts are inline text, never pills: the number first, then the grey word.
  it "renders a numeric count as the number followed by the word" do
    render_inline(described_class.new(label: "Tickets", value: 12))

    expect(page.text.squish).to eq("12 tickets")
  end

  it "keeps an acronym label as written" do
    render_inline(described_class.new(label: "CPU", value: 23))

    expect(page.text.squish).to eq("23 CPU")
  end

  it "keeps the label first when the value is not a number" do
    render_inline(described_class.new(label: "Ultimo controllo", value: "2 ore fa"))

    expect(page.text.squish).to eq("Ultimo controllo: 2 ore fa")
  end

  it "is not a pill" do
    render_inline(described_class.new(label: "Tickets", value: 12))

    expect(page).not_to have_css("span.border")
    expect(page).not_to have_css("span.bg-white")
  end

  it "renders a filtering count as an underlined link, pressed when its filter is on" do
    render_inline(described_class.new(label: "Da fare", value: 3, href: "/t?status=todo", active: true))

    expect(page).to have_css("a.underline[href='/t?status=todo'][aria-current='true']", text: "3 da fare")
  end

  it "valore neutro di default (zinc-900)" do
    render_inline(described_class.new(label: "Tickets", value: 12))
    expect(page).to have_css("span.font-mono.text-zinc-900", text: "12")
  end

  it "applica le classi letterali del colore valore (amber)" do
    render_inline(described_class.new(label: "Open", value: 6, value_color: :amber))
    expect(page).to have_css("span.text-amber-600", text: "6")
  end

  it "applica le classi letterali del colore valore (red)" do
    render_inline(described_class.new(label: "Livello", value: "fatal", value_color: :red))
    expect(page).to have_css("span.text-red-600", text: "fatal")
  end

  it "fa fallback a neutro per un colore fuori mappa (niente raise)" do
    expect { render_inline(described_class.new(label: "X", value: 1, value_color: :fuchsia)) }.not_to raise_error
    expect(page).to have_css("span.text-zinc-900", text: "1")
  end

  # CYRA-552 — i chiamanti scrivono `value_color: (condizione ? :emerald : nil)`: nil vuol dire
  # "nessun colore semantico", non "pagina rotta".
  it "fa fallback a neutro quando il colore è nil (niente raise)" do
    expect { render_inline(described_class.new(label: "Correzione", value: "nessuna", value_color: nil)) }
      .not_to raise_error
    expect(page).to have_css("span.text-zinc-900", text: "nessuna")
  end

  # CYRA-568 — le chip in testata sono la prima forma in cui si legge un conteggio: se scrivono
  # «2841» mentre il resto della pagina scrive «2.841», sembrano due numeri diversi.
  it "scrive le migliaia di un valore numerico come le scrive la lingua" do
    I18n.with_locale(:it) do
      render_inline(described_class.new(label: "Errori", value: 2841))
      expect(page).to have_text("2.841")
    end
  end

  it "lascia intatto un valore che non è un numero" do
    render_inline(described_class.new(label: "Progetto", value: "1000 Miglia"))
    expect(page).to have_text("1000 Miglia")
  end

  it "applica il data-test quando passato" do
    render_inline(described_class.new(label: "Tickets", value: 12, test_id: "projects-count-tickets"))
    expect(page).to have_css("span[data-test='projects-count-tickets']")
  end
end
