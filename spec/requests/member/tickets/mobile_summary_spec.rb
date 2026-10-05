# frozen_string_literal: true

require "rails_helper"

# CYRA-819 — Sul telefono la griglia della show impila: prima la colonna della scheda aperta, poi la
# sidebar. Stato e priorità vivono nel pannello Dettagli (CYRA-65), cioè in fondo alla sidebar: su
# uno schermo da 390 px finiscono oltre due schermate sotto il corpo del ticket, mentre i comandi
# (Segui, Prendi in carico, il menu) stanno subito sotto il titolo. Per sapere a che punto è il
# lavoro prima di intervenire bisognava scorrere fino in fondo e tornare su.
#
# Il riepilogo compatto vive nella riga chip dell'header, sopra i comandi, e SOLO sotto lg: da lg in
# su sparisce e la direzione desktop resta quella di CYRA-65, il pannello Dettagli in colonna destra.
RSpec.describe "Member ticket · riepilogo compatto su telefono", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:status) { create(:ticket_status, organization:, code: "in_progress", label: "In lavorazione", color: "amber") }
  let(:priority) { create(:ticket_priority, organization:, code: "high", label: "Alta", color: "red") }
  let(:ticket) { create(:ticket, organization:, project:, status:, priority:) }
  let(:account) { create(:account) }

  before do
    create(:membership, :owner, organization:, account:)
    create(:project_membership, project:, account:)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def documento
    Nokogiri::HTML(response.body)
  end

  it "mostra stato e priorità nell'intestazione, con la loro etichetta" do
    get member_ticket_path(ticket)

    riepilogo = documento.at_css("[data-test='ticket-mobile-summary']")
    expect(riepilogo).to be_present
    expect(riepilogo.text).to include(status.display_label, priority.display_label)
    expect(riepilogo.text).to include(I18n.t("member.tickets.show.status"),
                                      I18n.t("member.tickets.show.priority"))
  end

  # Il punto del ticket: arrivarci senza attraversare il corpo. Nel documento il riepilogo precede
  # sia la scheda aperta sia il pannello Dettagli.
  it "sta prima del corpo del ticket e prima del pannello Dettagli" do
    get member_ticket_path(ticket)

    posizioni = %w[ticket-mobile-summary ticket-tabs ticket-details].map do |test_id|
      response.body.index(%(data-test="#{test_id}"))
    end

    expect(posizioni).to all(be_present)
    expect(posizioni).to eq(posizioni.sort)
  end

  # Su schermo largo il riepilogo non c'è: `lg:hidden` lo spegne e resta il pannello Dettagli.
  it "sparisce da lg in su, dove il pannello Dettagli resta al suo posto" do
    get member_ticket_path(ticket)

    expect(documento.at_css("[data-test='ticket-mobile-summary']")["class"]).to include("lg:hidden")
    expect(documento.at_css("[data-test='ticket-details']")).to be_present
    expect(documento.at_css("[data-test='detail-status']")).to be_present
    expect(documento.at_css("[data-test='detail-priority']")).to be_present
  end

  # Rischio scritto nel ticket: due elementi con lo stesso id e il replace realtime ne aggiorna uno
  # solo — l'altro resterebbe fermo sullo stato vecchio senza che nulla lo segnali.
  it "non ripete l'identificatore del badge stato usato dagli aggiornamenti automatici" do
    get member_ticket_path(ticket)

    id_badge = "#{ActionView::RecordIdentifier.dom_id(ticket)}_status"
    expect(documento.css("##{id_badge}").size).to eq(1)
    expect(documento.css("[data-test='ticket-status-badge']").size).to be <= 1
  end

  # E nemmeno i controlli: cambiare stato resta una cosa sola, nel pannello Dettagli.
  it "è di sola lettura: nessun comando dentro il riepilogo" do
    get member_ticket_path(ticket)

    riepilogo = documento.at_css("[data-test='ticket-mobile-summary']")
    expect(riepilogo.css("form, button, a, details, input, select")).to be_empty
  end

  # Chi non gestisce il ticket vede lo stato in sola lettura anche nel pannello: il riepilogo non
  # cambia forma e non compare due volte.
  it "vale anche per chi il ticket non lo gestisce" do
    lettore = create(:account)
    create(:membership, :member, organization:, account: lettore)
    create(:project_membership, project:, account: lettore)
    delete logout_path
    post login_path, params: { email: lettore.email, password: "Secret123!" }

    get member_ticket_path(ticket)

    expect(documento.at_css("[data-test='ticket-mobile-summary']").text)
      .to include(status.display_label, priority.display_label)
    expect(documento.css("##{ActionView::RecordIdentifier.dom_id(ticket)}_status").size).to eq(1)
  end
end
