# frozen_string_literal: true

require "rails_helper"

# CYRA-569 — regressione di CYRA-392: dentro la stessa schermata lo stesso stato aveva due nomi,
# uno tradotto e uno inglese. Qui i due scenari del ticket su pagine vere, con l'account in
# italiano: il menu dello stato sulla scheda e il filtro della priorità nella lista devono leggere
# le stesse parole delle colonne accanto.
RSpec.describe "Lessico di stato e priorità nei menu", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account, locale: "it") }
  let(:project) { create(:project, organization: org) }
  let(:in_review) { org.ticket_statuses.find_by(code: "in_review") }
  let(:high) { org.ticket_priorities.find_by(code: "high") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "il menu dello stato sulla scheda del ticket" do
    let!(:ticket) { create(:ticket, organization: org, project: project, status: in_review, priority: high) }

    # Il confronto sta sul solo frammento del menu e non su tutta la risposta: il resto della
    # pagina è pieno di identificativi casuali e di testi che non c'entrano con lo stato.
    it "scrive il badge e tutte le voci in italiano" do
      sign_in(owner)
      get member_ticket_path(ticket)

      menu = Nokogiri::HTML(response.body).at_css("[data-test='ticket-status']").text
      expect(menu).to include("Aperto", "In lavorazione", "In revisione", "Risolto", "Chiuso")
      %w[Open Progress Review Resolved Closed].each { |inglese| expect(menu).not_to include(inglese) }
    end

    # Il caso osservato: badge «In Review» sulla scheda, riga «In revisione» nella lista. Il ticket
    # in lista è uno solo, quindi la riga trovata è la sua.
    it "dà allo stesso ticket lo stesso nome che la lista gli dà" do
      sign_in(owner)
      get list_member_tickets_path
      riga = Nokogiri::HTML(response.body).at_css("[data-test='ticket-row']").text

      get member_ticket_path(ticket)
      badge = Nokogiri::HTML(response.body).at_css("[data-test='ticket-status-badge']").text.strip

      expect(badge).to eq("In revisione")
      expect(riga).to include(badge)
    end

    it "in inglese resta inglese" do
      owner.update!(locale: "en")
      sign_in(owner)
      get member_ticket_path(ticket)

      menu = Nokogiri::HTML(response.body).at_css("[data-test='ticket-status']").text
      expect(menu).to include("In Review", "Resolved")
    end
  end

  describe "il filtro della priorità nella lista" do
    it "offre le stesse parole che scrive nella colonna accanto" do
      sign_in(owner)
      create(:ticket, organization: org, project: project, priority: high)

      get list_member_tickets_path

      doc = Nokogiri::HTML(response.body)
      voci = doc.css("select[data-test='filter-priority'] option").map { |o| o.text.strip }
      expect(voci).to include("Bassa", "Media", "Alta")
      expect(voci).not_to include("Low", "Medium", "High")
    end
  end

  # Gli altri due posti dove la stessa tendina di stato e priorità restava in inglese: la scheda del
  # progetto e la conversione di un'idea in ticket.
  describe "gli altri menu a tendina di stato e priorità" do
    # La barra dei filtri esiste solo se il progetto ha almeno un ticket.
    it "sulla scheda del progetto offrono i nomi italiani" do
      create(:ticket, organization: org, project: project, status: in_review, priority: high)
      sign_in(owner)

      get member_project_path(project)

      doc = Nokogiri::HTML(response.body)
      stati = doc.css("select[data-test='filter-status'] option").map { |o| o.text.strip }
      priorita = doc.css("select[data-test='filter-priority'] option").map { |o| o.text.strip }
      expect(stati).to include("Aperto", "In revisione", "Risolto")
      expect(stati).not_to include("Open", "In Review", "Resolved")
      expect(priorita).to include("Bassa", "Media", "Alta")
      expect(priorita).not_to include("Low", "Medium", "High")
    end

    it "nella conversione di un'idea offrono i nomi italiani" do
      idea = create(:idea, organization: org, project: project, author: owner)
      sign_in(owner)

      get new_member_idea_conversion_path(idea)

      doc = Nokogiri::HTML(response.body)
      stati = doc.css("select[data-test='idea-convert-status-select'] option").map { |o| o.text.strip }
      priorita = doc.css("select[data-test='idea-convert-priority-select'] option").map { |o| o.text.strip }
      expect(stati).to include("Aperto", "In revisione")
      expect(stati).not_to include("Open", "In Review")
      expect(priorita).to include("Bassa", "Alta")
      expect(priorita).not_to include("Low", "High")
    end
  end

  # Stesso ticket, altra pagina: la barra dell'errore collegato diceva «In Review».
  describe "lo stato del ticket collegato a un errore" do
    it "è scritto come nella lista dei ticket" do
      ticket = create(:ticket, organization: org, project: project, status: in_review, priority: high)
      group = create(:error_group, project: project, ticket: ticket)
      sign_in(owner)

      get member_monitoring_error_group_path(group)

      badge = Nokogiri::HTML(response.body).at_css("[data-test='error-ticket-bar-status']").text.strip
      expect(badge).to eq("In revisione")
    end
  end

  # CYRA-820 — in mezzo a cinque nomi italiani la striscia del ticket diceva «Questions». Due ticket
  # perché la striscia è la stessa su ognuno: un nome che dipendesse dal contenuto si vedrebbe solo
  # confrontandone due. E la lingua è quella dell'account, mai il ripiego: in inglese la scheda deve
  # dire Questions perché la voce inglese esiste, non perché l'italiano manca.
  describe "i nomi delle schede sulla scheda del ticket" do
    # The analysis tab shows only when there is an analysis (CYRA-883).
    let!(:primo) do
      create(:ticket, organization: org, project: project, status: in_review, priority: high, technical_analysis: "Notes")
    end
    let!(:secondo) { create(:ticket, organization: org, project: project, technical_analysis: "Notes") }

    def striscia = Nokogiri::HTML(response.body).at_css("[data-test='ticket-tabs']")

    def strisce_dei_due
      get member_ticket_path(primo)
      prima = striscia
      # Il secondo giro ricarica la stessa pagina: sessione, organizzazione e campanella del topbar
      # rifanno le stesse query, e prosopite le leggerebbe come un N+1 che in produzione non esiste
      # (là sono due richieste separate). Il primo giro resta scansionato: la pagina non perde la
      # sua guardia.
      allow_n_plus_one { get member_ticket_path(secondo) }
      [ prima, striscia ]
    end

    it "in italiano le scrive tutte in italiano" do
      sign_in(owner)

      strisce_dei_due.each do |nodo|
        expect(nodo.text).to include("Dettaglio", "Analisi tecnica", "Automazione", "Domande", "Discussione")
        expect(nodo.text).not_to include("Questions")
        # Il segnaposto di i18n: è così che «Questions» era arrivato in pagina, non come traduzione.
        expect(nodo.to_html).not_to include("translation_missing")
      end
    end

    it "in inglese resta inglese, senza ricadere sull'italiano" do
      owner.update!(locale: "en")
      sign_in(owner)

      strisce_dei_due.each do |nodo|
        expect(nodo.text).to include("Detail", "Technical analysis", "Automation", "Questions", "Discussion")
        expect(nodo.text).not_to include("Domande")
        expect(nodo.to_html).not_to include("translation_missing")
      end
    end
  end

  # Una priorità inventata dall'organizzazione non ha traduzione: deve restare la sua etichetta.
  describe "una priorità personalizzata" do
    it "resta scritta come l'ha chiamata l'organizzazione" do
      create(:ticket_priority, organization: org, code: "bloccante", label: "Bloccante", color: "red", position: 9)
      sign_in(owner)

      get list_member_tickets_path

      voci = Nokogiri::HTML(response.body).css("select[data-test='filter-priority'] option").map { |o| o.text.strip }
      expect(voci).to include("Bloccante")
    end
  end
end
