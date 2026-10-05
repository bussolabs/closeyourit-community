# frozen_string_literal: true

require "rails_helper"

# CYRA-555 — filtrare senza trovare corrispondenze faceva dire alle pagine che i dati non esistono
# («Ancora nessuna idea» con cinquanta idee in alto), e non offriva un modo per togliere il filtro.
# Il componente rende obbligate le due cose che mancavano: dichiarare che è la RICERCA a non aver
# trovato niente, e la via d'uscita per tornare all'elenco intero.
RSpec.describe Ui::NoResultsComponent, type: :component do
  def rendi(**opzioni)
    render_inline(described_class.new(reset_href: "/member/teams", test_id: "teams-no-results", **opzioni))
  end

  it "cita quello che è stato cercato, invece di dire che l'elenco è vuoto" do
    pagina = rendi(query: "zqxwvbnm")

    expect(pagina.css("[data-test='no-results-title']").text).to include("zqxwvbnm")
  end

  it "su un indirizzo che ha già una query, il marker di azzeramento si accoda con &" do
    pagina = render_inline(described_class.new(reset_href: "/member/errors?range=7d",
                                               reset_test_id: "errors-reset"))

    expect(pagina.css("[data-test='errors-reset']").first[:href]).to eq("/member/errors?range=7d&ft=1")
  end

  it "senza testo cercato parla di filtri, non di ricerca" do
    pagina = rendi

    expect(pagina.css("[data-test='no-results-title']").text).to eq(I18n.t("ui.no_results.title_filtered"))
    expect(pagina.css("a").first.text).to include(I18n.t("ui.no_results.reset_filters"))
  end

  it "offre SEMPRE il modo di togliere quello che si è cercato" do
    pagina = rendi(query: "zqxwvbnm", reset_test_id: "teams-reset-search")

    azzera = pagina.css("[data-test='teams-reset-search']").first
    expect(azzera).to be_present
    # CYRA-694 — il marker ft=1 fa dimenticare anche i filtri ricordati in sessione: senza,
    # il ritorno all'elenco «pulito» verrebbe rediretto sui filtri appena tolti.
    expect(azzera[:href]).to eq("/member/teams?ft=1")
    expect(azzera.text).to include(I18n.t("ui.no_results.reset_search"))
  end

  it "dice quanti elementi ci sono davvero quando il chiamante lo passa" do
    pagina = rendi(query: "zqxwvbnm", body: "Ci sono 6 team, ma nessuno corrisponde.")

    expect(pagina.css("[data-test='no-results-body']").text).to include("Ci sono 6 team")
  end

  it "senza corpo non lascia un paragrafo vuoto (colonne strette della bacheca)" do
    pagina = rendi(compact: true)

    expect(pagina.css("[data-test='no-results-body']")).to be_empty
    expect(pagina.to_html).to include("py-8")
  end

  it "porta le azioni extra del chiamante accanto ad azzera" do
    pagina = render_inline(described_class.new(reset_href: "/member/tickets", query: "zqx")) do |vuoto|
      vuoto.with_action { '<a href="/member/tickets/ask">Chiedi ai ticket</a>'.html_safe }
    end

    expect(pagina.css("a").map(&:text)).to include("Chiedi ai ticket")
  end

  it "passa i data del chiamante al bottone di azzeramento (uscita dal turbo-frame)" do
    pagina = rendi(query: "zqx", reset_test_id: "teams-reset-search", reset_data: { turbo_frame: "_top" })

    expect(pagina.css("[data-test='teams-reset-search'][data-turbo-frame='_top']")).to be_present
  end

  # DESIGN.md E24 — same height rule as the empty state: down to the frame, unless compact.
  it "marks itself to fill the page, unless compact" do
    expect(rendi.css("[data-test='teams-no-results']").first["data-empty-fill"]).to be_present
    expect(rendi(compact: true).css("[data-test='teams-no-results']").first["data-empty-fill"]).to be_nil
  end
end
