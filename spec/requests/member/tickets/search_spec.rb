# frozen_string_literal: true

require "rails_helper"

# CYRA-387: la ricerca testuale (ramo ILIKE) guardava solo il titolo e cercava la stringa intera;
# a zero risultati la lista dichiarava «nessun ticket» e portava i chip a zero anche a chi ne ha
# mille. Qui: l'indice copre descrizione/analisi/scenari spezzando la query in termini, e l'empty
# state distingue «nessun risultato» da «nessun ticket» tenendo i chip sul totale reale.
#
# Ramo ILIKE: nessun `semantic=1`, così i test sono deterministici e non toccano il servizio embedding.
RSpec.describe "Member::Tickets — ricerca testuale ed empty state", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    sign_in(member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "l'indice va oltre il titolo (Scenario 1)" do
    it "trova un ticket per una parola presente solo nella descrizione" do
      match = create(:ticket, :plain_bug, organization: org, project: project, status: status,
        title: "Titolo generico", description: "Le ore di silenzio prima del deploy")
      other = create(:ticket, organization: org, project: project, status: status, title: "Altro tema")

      get list_member_tickets_path, params: { q: "silenzio" }

      expect(response.body).to include(match.code)
      expect(response.body).not_to include(other.code)
    end

    it "trova un ticket per una parola presente solo nell'analisi tecnica" do
      match = create(:ticket, organization: org, project: project, status: status,
        title: "Titolo generico", technical_analysis: "Riscrivere il pagamento con idempotenza forte")

      get list_member_tickets_path, params: { q: "idempotenza" }

      expect(response.body).to include(match.code)
    end

    it "trova un ticket per una parola presente solo in uno scenario" do
      match = create(:ticket, organization: org, project: project, status: status,
        title: "Titolo generico", with_default_body: false,
        scenarios_attributes: [ { step_given: "Utente su Safari", step_when: "clicca checkout",
                                  step_then: "non accade nulla", step_expected: "prosegue al pagamento" } ])

      get list_member_tickets_path, params: { q: "Safari" }

      expect(response.body).to include(match.code)
    end

    it "spezza la query multi-parola in termini invece di cercare la stringa intera" do
      # «ore» e «silenzio» compaiono entrambi ma non sono contigui: la stringa intera non matcha.
      match = create(:ticket, :plain_bug, organization: org, project: project, status: status,
        title: "Titolo", description: "Le ore di silenzio prima del rilascio")

      get list_member_tickets_path, params: { q: "ore silenzio" }

      expect(response.body).to include(match.code)
    end

    it "richiede che tutti i termini compaiano (AND fra le parole)" do
      only_one = create(:ticket, :plain_bug, organization: org, project: project, status: status,
        title: "Titolo", description: "Qui parliamo solo di deploy")

      get list_member_tickets_path, params: { q: "deploy parolamancante" }

      expect(response.body).not_to include(only_one.code)
    end
  end

  describe "il match esatto per codice resta prioritario (rischio dichiarato)" do
    it "cercare un codice esistente lo restituisce anche col nuovo indice" do
      target = create(:ticket, organization: org, project: project, status: status, title: "Bersaglio")

      get list_member_tickets_path, params: { q: target.code }

      expect(response.body).to include(target.code)
    end
  end

  describe "nessun risultato non vuol dire nessun ticket (Scenario 2)" do
    it "a zero risultati mostra l'empty di ricerca: cita la query e offre di azzerare, non «nessun ticket»" do
      create(:ticket, organization: org, project: project, status: status, title: "Un ticket qualsiasi")

      get list_member_tickets_path, params: { q: "parolachenonesistemai" }

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-no-results']")
      expect(html).to have_css("[data-test='tickets-reset-search']")
      expect(response.body).to include("parolachenonesistemai")
      expect(html).not_to have_css("[data-test='tickets-empty']")
    end

    it "a zero risultati i chip contano comunque i ticket reali, non zero" do
      # allow_n_plus_one: fixture bulk nel setup (la factory legge agent_workflow per ticket), non
      # N+1 di produzione — la request esercitata sotto è single-shot.
      allow_n_plus_one { create_list(:ticket, 3, organization: org, project: project, status: status) }

      get list_member_tickets_path, params: { q: "parolachenonesistemai" }

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-count-tickets']", text: "3")
    end

    it "i bottoni dell'empty di ricerca escono dal turbo-frame (navigazione full-page)" do
      create(:ticket, organization: org, project: project, status: status, title: "Un ticket")

      get list_member_tickets_path, params: { q: "parolachenonesistemai" }

      html = Capybara.string(response.body)
      # Reset e "Chiedi ai ticket" puntano FUORI dal frame tickets-results: senza _top il reset
      # non svuoterebbe la barra di ricerca (che sta fuori dal frame) e "Chiedi" caricherebbe una
      # pagina priva di quel frame → Turbo scarterebbe la risposta. Stessa ragione dei link di riga.
      expect(html).to have_css("[data-test='tickets-reset-search'][data-turbo-frame='_top']")
      expect(html).to have_css("[data-test='tickets-no-results-ask'][data-turbo-frame='_top']")
    end

    it "senza ricerca né ticket mostra l'empty «ancora nessun ticket»" do
      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-empty']")
      expect(html).not_to have_css("[data-test='tickets-no-results']")
    end

    it "un filtro senza risultati mostra l'empty di ricerca, non «nessun ticket»" do
      create(:ticket, organization: org, project: project, status: status)
      other_project = create(:project, organization: org)
      create(:project_membership, account: member, project: other_project)

      get list_member_tickets_path, params: { project_id: [ other_project.id ] }

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-no-results']")
      expect(html).not_to have_css("[data-test='tickets-empty']")
    end
  end

  describe "board: la ricerca a vuoto non azzera i chip" do
    it "i chip contano i ticket reali anche a zero risultati" do
      # allow_n_plus_one: fixture bulk nel setup (vedi sopra), non N+1 di produzione.
      allow_n_plus_one { create_list(:ticket, 2, organization: org, project: project, status: status) }

      get member_tickets_path, params: { q: "parolachenonesistemai" }

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='board-stat-tickets']", text: "2")
    end
  end
end
