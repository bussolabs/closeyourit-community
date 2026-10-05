# frozen_string_literal: true

require "rails_helper"

# CYRA-844 — «quali ticket hanno domande ancora senza risposta?» si scopriva solo aprendo i ticket
# uno per uno. Qui: l'etichetta sulla riga e sulla card, il contatore in testa a lista e bacheca,
# il filtro condivisibile (`?questions=open`) e la regola che una domanda risposta o ritirata non
# conta più. Stesso disegno del contatore «Aspettano te» (CYRA-374).
RSpec.describe "Member::Tickets — le domande senza risposta sulla lista (CYRA-844)", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:open_status) { create(:ticket_status, organization: org) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    sign_in(member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def ticket(title: Faker::Lorem.sentence)
    create(:ticket, organization: org, project: project, status: open_status, title: title)
  end

  def question(ticket, *traits)
    create(:ticket_question, *traits, ticket: ticket, organization: org, author: member)
  end

  describe "la riga si riconosce senza aprire il ticket" do
    it "la riga della lista porta l'etichetta col numero di domande aperte" do
      con_domande = ticket
      allow_n_plus_one { 2.times { question(con_domande) } }

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='ticket-open-questions-#{con_domande.id}']", text: "2")
    end

    it "l'etichetta porta alla scheda Domande di quel ticket" do
      con_domande = ticket
      question(con_domande)

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("a[data-test='ticket-open-questions-#{con_domande.id}'][href*='tab=questions']")
    end

    it "una domanda risposta o ritirata non conta" do
      risposta = ticket
      question(risposta, :answered)
      ritirata = ticket
      question(ritirata).update!(closed_at: Time.current, closed_by: member)

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).not_to have_css("[data-test='ticket-open-questions-#{risposta.id}']")
      expect(html).not_to have_css("[data-test='ticket-open-questions-#{ritirata.id}']")
    end

    it "la card della bacheca porta la stessa etichetta" do
      con_domande = ticket
      question(con_domande)
      senza = ticket

      get member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='board-card-open-questions-#{con_domande.id}']", text: "1")
      expect(html).not_to have_css("[data-test='board-card-open-questions-#{senza.id}']")
    end
  end

  describe "il contatore in testa conta i ticket con domande aperte" do
    it "la lista mostra il contatore" do
      allow_n_plus_one do
        primo = ticket
        2.times { question(primo) }
        question(ticket)
        question(ticket, :answered)
      end

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-count-open-questions']", text: "2")
    end

    it "la bacheca mostra lo stesso contatore" do
      allow_n_plus_one { 2.times { question(ticket) } }

      get member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='board-stat-open-questions']", text: "2")
    end

    it "a zero resta scritto ma non è un link" do
      ticket

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-count-open-questions']", text: "0")
      expect(html).not_to have_css("a[data-test='tickets-count-open-questions']")
    end

    it "conta solo i ticket dei progetti che vedo" do
      altrove = create(:project, organization: org)
      question(create(:ticket, organization: org, project: altrove, status: open_status))

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-count-open-questions']", text: "0")
    end

    it "non scende per una ricerca attiva" do
      allow_n_plus_one { 2.times { question(ticket(title: "Da chiarire")) } }

      get list_member_tickets_path, params: { q: "parolachenonesistemai" }

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-count-open-questions']", text: "2")
    end
  end

  describe "un click sul contatore filtra l'elenco" do
    it "il contatore è un link a ?questions=open" do
      question(ticket)

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("a[data-test='tickets-count-open-questions'][href*='questions=open']")
    end

    it "l'elenco filtrato contiene solo i ticket con domande aperte" do
      con_domande = ticket
      question(con_domande)
      risposta = ticket
      question(risposta, :answered)
      senza = ticket

      get list_member_tickets_path, params: { questions: "open" }

      expect(response.body).to include(con_domande.code)
      expect(response.body).not_to include(risposta.code)
      expect(response.body).not_to include(senza.code)
    end

    it "il filtro vale anche sulla bacheca" do
      con_domande = ticket
      question(con_domande)
      senza = ticket

      get member_tickets_path, params: { questions: "open" }

      expect(response.body).to include(con_domande.code)
      expect(response.body).not_to include(senza.code)
    end

    it "col filtro acceso il contatore spegne il filtro invece di riaccenderlo" do
      question(ticket)

      get list_member_tickets_path, params: { questions: "open" }

      html = Capybara.string(response.body)
      expect(html).to have_css("a[data-test='tickets-count-open-questions'][aria-current='true']")
      expect(html).not_to have_css("a[data-test='tickets-count-open-questions'][href*='questions=open']")
    end

    it "un valore inventato in ?questions vale come nessun filtro" do
      con_domande = ticket
      question(con_domande)
      senza = ticket

      get list_member_tickets_path, params: { questions: "tutte" }

      expect(response.body).to include(con_domande.code)
      expect(response.body).to include(senza.code)
    end

    it "col filtro acceso e nessun risultato l'elenco dichiara i filtri, non «ancora nessun ticket»" do
      ticket

      get list_member_tickets_path, params: { questions: "open" }

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-no-results']")
      expect(html).not_to have_css("[data-test='tickets-empty']")
    end
  end
end
