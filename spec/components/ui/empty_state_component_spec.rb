# frozen_string_literal: true

require "rails_helper"

# CYRA-363 — lo stato vuoto è l'unico momento in cui il prodotto può insegnare sé stesso, ed era il
# momento in cui taceva. Il componente rende obbligate le quattro parti: chi scrive non può tornare
# alla frase secca senza aggirarlo.
RSpec.describe Ui::EmptyStateComponent, type: :component do
  def rendi(**opzioni, &blocco)
    render_inline(described_class.new(
      title: "Ancora nessun controllo", body: "Serve a sapere se il sito risponde.",
      example: "Per esempio: Sito pubblico, ogni minuto.", test_id: "vuoto", **opzioni
    ), &blocco)
  end

  it "mostra cosa manca, a cosa serve e un esempio concreto" do
    pagina = rendi

    expect(pagina.css("[data-test='empty-title']").text).to include("Ancora nessun controllo")
    expect(pagina.css("[data-test='empty-body']").text).to include("Serve a sapere")
    expect(pagina.css("[data-test='empty-example']").text).to include("Per esempio")
  end

  it "l'azione compare solo se il chiamante la passa" do
    senza = rendi
    expect(senza.css("a, button")).to be_empty

    con = rendi { |vuoto| vuoto.with_action { "<a href=\"/x\">Crea</a>".html_safe } }
    expect(con.css("a").text).to eq("Crea")
  end

  it "nella forma compatta resta tutto, con meno aria" do
    pagina = rendi(compact: true)

    expect(pagina.css("[data-test='empty-example']")).to be_present
    expect(pagina.to_html).to include("py-8")
  end

  it "framed draws the dashed page box itself, so no page writes it by hand" do
    framed = rendi(framed: true).css("[data-test='vuoto']").first
    plain = rendi.css("[data-test='vuoto']").first

    expect(framed[:class]).to include("border-dashed", "rounded-lg", "bg-white")
    expect(plain[:class]).not_to include("border-dashed")
  end

  # DESIGN.md E24 — a page-level empty state fills the page down to the frame; a compact one stays small.
  it "marks itself to fill the page, unless compact" do
    expect(rendi.css("[data-test='vuoto']").first["data-empty-fill"]).to be_present
    expect(rendi(compact: true).css("[data-test='vuoto']").first["data-empty-fill"]).to be_nil
  end
end
