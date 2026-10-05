# frozen_string_literal: true

require "rails_helper"

# CYRA-265 — il resoconto di lavorazione ha una scheda sua. Fino a qui esisteva solo lato dati e via
# CLI (CYRA-220): modello, versioni, tetto e API c'erano, ma dal web non c'era nessun posto dove
# leggerlo.
#
# Non è una comodità: è la precondizione dichiarata da lib/tasks/comment_compaction.rake, che
# avverte di non lanciare `apply` finché la sezione non è online. Senza, la compattazione chiude 619
# commenti con "(resoconto v2)" indicando un posto che dal web non esiste.
#
# Scheda di sola LETTURA: il resoconto lo scrivono la CLI e la migrazione.
RSpec.describe "Member ticket report tab", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:) }
  # Nome con apostrofo di proposito (CYRA-448, fix del flaky): il nome finto veniva da Faker, e
  # quando gli capitava un «D'Amore» l'HTML lo scriveva `&#39;` — il confronto sulla stringa grezza
  # falliva a caso, una build sì e dieci no. Ora il caso scomodo è la NORMA del test.
  let(:owner) { create(:account, name: "Christian D'Amore") }

  # Etichette in grassetto: sono la forma prevista da closeyourit-writing.md, ed è esattamente ciò
  # che si leggeva coi suoi asterischi finché il testo non veniva reso.
  let(:body) { "**Fatto:** recinto chiuso, CI verde.\n\n**Rischi:** il job gira solo fuori dalle PR." }

  before do
    create(:membership, :owner, organization:, account: owner)
    create(:project_membership, project:, account: owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def record(text, author: owner)
    Ticketing::RecordReport.call(ticket:, author:, body: text)
  end

  describe "quando il resoconto c'è" do
    before { record(body) }

    it "mostra la scheda nella striscia" do
      get member_ticket_path(ticket)

      expect(response.body).to include('data-test="ticket-tab-report"')
      expect(response.body).to include(member_ticket_path(ticket, tab: "report"))
    end

    it "rende il resoconto col markdown, non coi simboli in chiaro" do
      get member_ticket_path(ticket, tab: "report")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="ticket-report"')
      expect(response.body).to match(%r{<h4[^>]*>Fatto</h4>})
      expect(response.body).not_to include("**Fatto:**")
    end

    it "dice quale versione si sta leggendo e chi l'ha scritta" do
      get member_ticket_path(ticket, tab: "report")

      # Si legge il TESTO reso, non il sorgente: l'apostrofo nell'HTML è un'entità, e chi guarda la
      # pagina vede il nome, non l'entità.
      expect(Nokogiri::HTML(response.body).text).to include(owner.name)
    end

    # Il corrente è la versione col numero PIÙ ALTO, non l'ultima riga scritta: l'associazione ha già
    # un order(:version) ascendente, e sbagliare qui mostrerebbe la stesura numero 1 spacciandola per
    # quella buona (stessa trappola documentata in Ticketing::RecordReport#current).
    it "mostra la versione corrente, non la prima" do
      record("**Fatto:** la seconda stesura, quella giusta.")

      get member_ticket_path(ticket, tab: "report")

      scheda = Nokogiri::HTML(response.body).at_css("[data-test='ticket-report']").text
      expect(scheda).to include("la seconda stesura, quella giusta")
      expect(scheda).not_to include("recinto chiuso")
    end

    it "elenca le versioni precedenti" do
      record("**Fatto:** la seconda stesura.")

      get member_ticket_path(ticket, tab: "report")

      expect(response.body).to include('data-test="ticket-report-versions"')
      expect(response.body).to include(member_ticket_report_version_path(ticket, 1))
    end

    it "con una sola versione non mostra lo storico" do
      get member_ticket_path(ticket, tab: "report")

      expect(response.body).not_to include('data-test="ticket-report-versions"')
    end

    it "apre una versione vecchia e la rende" do
      record("**Fatto:** la seconda stesura.")

      get member_ticket_report_version_path(ticket, 1)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("recinto chiuso")
    end
  end

  describe "quando il resoconto non c'è" do
    it "non mostra la scheda nella striscia" do
      get member_ticket_path(ticket)

      expect(response.body).not_to include('data-test="ticket-tab-report"')
    end

    # ?tab=report su un ticket senza resoconto non deve dare una scheda vuota né un errore: si
    # torna al dettaglio, come per un tab sconosciuto.
    it "riporta al dettaglio invece di aprire una scheda vuota" do
      get member_ticket_path(ticket, tab: "report")

      expect(response).to have_http_status(:ok)
      # La scheda Dettaglio è quella attiva: il tab "detail" ha aria-current, e nessun riquadro
      # resoconto è stato reso.
      expect(response.body).to include('data-test="ticket-tab-detail"')
      expect(response.body).not_to include('data-test="ticket-report"')
    end

    it "una versione che non esiste dà 404" do
      get member_ticket_report_version_path(ticket, 9)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "isolamento" do
    # Stesso confine di ogni altra scheda: un ticket di un'altra organizzazione non si apre, e non
    # deve nemmeno rivelare che esiste.
    it "il resoconto di un ticket di un'altra organizzazione non si legge" do
      other = create(:ticket, organization: create(:organization))

      get member_ticket_path(other, tab: "report")

      expect(response).to have_http_status(:not_found)
    end
  end
end
