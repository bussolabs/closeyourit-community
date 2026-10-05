# frozen_string_literal: true

require "rails_helper"

# CYRA-259 — l'analisi tecnica ha una scheda sua, con il markdown RESO. Prima viveva in coda al
# dettaglio, come testo grezzo: i titoli e gli elenchi si leggevano coi loro simboli, attaccati al
# corpo non tecnico del ticket.
RSpec.describe "Member ticket technical analysis tab", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, description: "Il corpo del ticket.", technical_analysis: analysis) }
  let(:analysis) { "## Rotte\n\n- primo passo\n- secondo passo\n\nIl gate vive in `TicketsController`." }
  let(:owner) { create(:account) }

  before do
    create(:membership, :owner, organization:, account: owner)
    create(:project_membership, project:, account: owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "rende il markdown dell'analisi tecnica nella sua scheda" do
    get member_ticket_path(ticket, tab: "analysis")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="ticket-technical-analysis"')
    # La prova che il markdown è RESO e non stampato: titolo (Commonmarker gli infila l'anchor
    # dell'id, quindi il match sta sulla chiusura), voci di elenco e codice inline.
    expect(response.body).to include(">Rotte</h2>")
    expect(response.body).to include("<li>primo passo</li>")
    expect(response.body).to include("<code>TicketsController</code>")
    # E il sorgente grezzo non compare più nel testo reso (resta solo per «Copia Markdown»).
    expect(Nokogiri::HTML(response.body).at_css("[data-test='ticket-analysis-body']").text).not_to include("## Rotte")
  end

  it "espone la scheda nella striscia delle tab" do
    get member_ticket_path(ticket)

    expect(response.body).to include('data-test="ticket-tab-analysis"')
    expect(response.body).to include(member_ticket_path(ticket, tab: "analysis"))
  end

  it "toglie l'analisi tecnica dalla scheda Dettaglio" do
    get member_ticket_path(ticket)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="ticket-description"')
    expect(response.body).not_to include('data-test="ticket-technical-analysis"')
  end

  it "mostra un messaggio di assenza quando il ticket non ha analisi tecnica" do
    empty = create(:ticket, organization:, project:, technical_analysis: nil)

    get member_ticket_path(empty, tab: "analysis")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="ticket-technical-analysis-empty"')
    # Chi può modificare il ticket vede anche come rimediare.
    expect(response.body).to include(I18n.t("member.tickets.show.technical_analysis_empty_hint"))
  end

  # Il suggerimento "modifica il ticket" è inutile per chi non può: resta il solo messaggio d'assenza.
  it "non suggerisce la modifica a chi non gestisce i ticket" do
    empty = create(:ticket, organization:, project:, technical_analysis: nil)
    customer = create(:account)
    create(:membership, organization:, account: customer, role: :customer)
    create(:project_membership, project:, account: customer)
    post login_path, params: { email: customer.email, password: "Secret123!" }

    get member_ticket_path(empty, tab: "analysis")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="ticket-technical-analysis-empty"')
    expect(response.body).not_to include(I18n.t("member.tickets.show.technical_analysis_empty_hint"))
  end

  # Commonmarker gira in modalità safe: l'HTML grezzo nel sorgente non arriva MAI a destinazione come
  # markup, quindi l'output è marcabile html_safe senza un secondo sanitize — che spoglierebbe le
  # tabelle GFM. Da CYRA-261 esce ESCAPATO (testo visibile) invece che omesso: prima "usa <div> per il
  # layout" perdeva mezza frase in silenzio. L'analisi arriva anche da CLI e agenti: contratto inchiodato.
  it "non lascia passare l'HTML grezzo dentro l'analisi" do
    ticket.update!(technical_analysis: "<script>alert(1)</script>\n\nsegue testo")

    get member_ticket_path(ticket, tab: "analysis")

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("<script>alert(1)</script>")
    expect(response.body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
    expect(response.body).to include("<p>segue testo</p>")
  end

  # Aprire un ticket è baseline: anche un customer scrive la technical_analysis. Un'immagine remota
  # nel markdown sarebbe una richiesta dal browser di chi legge — tracking pixel su ogni membro che
  # apre la scheda. La CSP non ferma nulla (img_src ammette :https, ed è in report-only).
  it "non lascia partire immagini remote dall'analisi" do
    ticket.update!(technical_analysis: "![diagramma](https://tracker.example/pixel.png)\n\ne poi il testo")

    get member_ticket_path(ticket, tab: "analysis")

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("<img")
    # L'indirizzo resta leggibile, in chiaro: l'informazione non si perde.
    expect(response.body).to include("diagramma — https://tracker.example/pixel.png")
  end

  # Le immagini a stessa origine (allegati ActiveStorage) non chiamano nessuno: restano.
  it "lascia passare le immagini a stessa origine" do
    ticket.update!(technical_analysis: "![schema](/rails/active_storage/blobs/abc/schema.png)")

    get member_ticket_path(ticket, tab: "analysis")

    expect(response.body).to include('<img src="/rails/active_storage/blobs/abc/schema.png"')
  end

  # Un ?tab= inventato torna al dettaglio (whitelist TABS), non a una scheda vuota.
  it "ricade sul dettaglio con un tab sconosciuto" do
    get member_ticket_path(ticket, tab: "analisi-tecnica")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="ticket-description"')
    expect(response.body).not_to include('data-test="ticket-technical-analysis"')
  end
end
