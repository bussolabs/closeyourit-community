# frozen_string_literal: true

require "rails_helper"

# CYRA-374 — «quali ticket aspettano una mia decisione, adesso?» è la prima domanda di chi comincia
# la giornata, ed era l'unica a cui né la lista né la board rispondevano: le richieste lasciate dagli
# automatismi durante la notte si scoprivano aprendo i ticket uno per uno.
#
# Qui: il contatore in testa a board e lista, il filtro condivisibile (`?awaiting=me`), il badge che
# rende riconoscibile la riga senza aprirla, il filtro per revisore accanto a quello per assegnatario
# e — la parte che conta di più — la PARITÀ col numero della pagina Approvazioni, che è la ragione per
# cui la definizione di «aspetta te» vive in un posto solo.
RSpec.describe "Member::Tickets — le decisioni che aspettano me (CYRA-374)", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:collega) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:open_status) { create(:ticket_status, organization: org) }
  let(:review_status) { create(:ticket_status, :in_review, organization: org) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: collega, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    sign_in(member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def review_ticket(reviewer:, title: Faker::Lorem.sentence)
    create(:ticket, organization: org, project: project, status: review_status, reviewer: reviewer, title: title)
  end

  describe "Scenario 1 — la mattina apro l'elenco e leggo quante decisioni aspettano me" do
    it "la lista mostra il contatore con le sole decisioni che aspettano me" do
      allow_n_plus_one do
        2.times { review_ticket(reviewer: member) }
        review_ticket(reviewer: collega)
        create(:ticket, organization: org, project: project, status: open_status, reviewer: member)
      end

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-count-awaiting']", text: "2")
    end

    it "la board mostra lo stesso contatore" do
      allow_n_plus_one do
        2.times { review_ticket(reviewer: member) }
        review_ticket(reviewer: collega)
      end

      get member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='board-stat-awaiting']", text: "2")
    end

    it "il contatore è a zero quando non aspetta niente, e allora non è un link" do
      create(:ticket, organization: org, project: project, status: open_status, reviewer: member)

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-count-awaiting']", text: "0")
      expect(html).not_to have_css("a[data-test='tickets-count-awaiting']")
    end

    it "conta solo i ticket dei progetti che vedo" do
      altrove = create(:project, organization: org)
      create(:ticket, organization: org, project: altrove, status: review_status, reviewer: member)

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-count-awaiting']", text: "0")
    end
  end

  describe "un click sul contatore filtra l'elenco, e l'indirizzo resta condivisibile" do
    it "il contatore è un link a ?awaiting=me" do
      review_ticket(reviewer: member)

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("a[data-test='tickets-count-awaiting'][href*='awaiting=me']")
    end

    it "l'elenco filtrato contiene esattamente i ticket che aspettano me" do
      mio = review_ticket(reviewer: member)
      altrui = review_ticket(reviewer: collega)
      aperto = create(:ticket, organization: org, project: project, status: open_status, reviewer: member)

      get list_member_tickets_path, params: { awaiting: "me" }

      expect(response.body).to include(mio.code)
      expect(response.body).not_to include(altrui.code)
      expect(response.body).not_to include(aperto.code)
    end

    it "il filtro vale anche sulla board" do
      mio = review_ticket(reviewer: member)
      altrui = review_ticket(reviewer: collega)

      get member_tickets_path, params: { awaiting: "me" }

      expect(response.body).to include(mio.code)
      expect(response.body).not_to include(altrui.code)
    end

    it "col filtro acceso il contatore spegne il filtro invece di riaccenderlo" do
      review_ticket(reviewer: member)

      get list_member_tickets_path, params: { awaiting: "me" }

      html = Capybara.string(response.body)
      expect(html).to have_css("a[data-test='tickets-count-awaiting'][aria-current='true']")
      expect(html).not_to have_css("a[data-test='tickets-count-awaiting'][href*='awaiting=me']")
    end

    # Il contatore risponde a «quante decisioni aspettano me», non «quante ne aspettano me tra
    # quelle che sto guardando»: se scendesse coi filtri, cliccarlo mostrerebbe un elenco più corto
    # del numero appena letto.
    it "il contatore non scende per una ricerca o per un altro filtro attivo" do
      allow_n_plus_one { 2.times { review_ticket(reviewer: member, title: "Da revisionare") } }

      get list_member_tickets_path, params: { q: "parolachenonesistemai" }

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-count-awaiting']", text: "2")
    end

    it "un valore inventato in ?awaiting vale come nessun filtro" do
      mio = review_ticket(reviewer: member)
      altrui = review_ticket(reviewer: collega)

      get list_member_tickets_path, params: { awaiting: "chiunque" }

      expect(response.body).to include(mio.code)
      expect(response.body).to include(altrui.code)
    end
  end

  describe "la riga si riconosce senza aprire il ticket" do
    it "la riga della lista porta il badge della decisione in sospeso" do
      mio = review_ticket(reviewer: member)

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='ticket-awaiting-#{mio.id}']")
    end

    it "il badge non compare sui ticket in revisione di qualcun altro" do
      altrui = review_ticket(reviewer: collega)

      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).not_to have_css("[data-test='ticket-awaiting-#{altrui.id}']")
    end

    it "la card della board porta lo stesso badge" do
      mio = review_ticket(reviewer: member)
      altrui = review_ticket(reviewer: collega)

      get member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='board-card-awaiting-#{mio.id}']")
      expect(html).not_to have_css("[data-test='board-card-awaiting-#{altrui.id}']")
    end
  end

  describe "filtro per revisore, come già si fa per l'assegnatario" do
    # `visible: :all`: i filtri vivono nel pannello della toolbar, che parte chiuso — come già fa
    # ogni altro filtro della stessa riga.
    it "la lista offre il filtro Revisore" do
      get list_member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("select[name='reviewer_id[]'][data-test='filter-reviewer']", visible: :all)
    end

    it "la board offre lo stesso filtro" do
      get member_tickets_path

      html = Capybara.string(response.body)
      expect(html).to have_css("select[name='reviewer_id[]'][data-test='filter-reviewer']", visible: :all)
    end

    it "filtra i ticket per chi deve revisionarli" do
      suo = review_ticket(reviewer: collega)
      mio = review_ticket(reviewer: member)

      get list_member_tickets_path, params: { reviewer_id: [ collega.id ] }

      expect(response.body).to include(suo.code)
      expect(response.body).not_to include(mio.code)
    end

    it "il filtro revisore vale anche sulla board" do
      suo = review_ticket(reviewer: collega)
      mio = review_ticket(reviewer: member)

      get member_tickets_path, params: { reviewer_id: [ collega.id ] }

      expect(response.body).to include(suo.code)
      expect(response.body).not_to include(mio.code)
    end

    it "col filtro revisore attivo l'elenco vuoto dichiara i filtri, non «ancora nessun ticket»" do
      review_ticket(reviewer: member)

      get list_member_tickets_path, params: { reviewer_id: [ collega.id ] }

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='tickets-no-results']")
      expect(html).not_to have_css("[data-test='tickets-empty']")
    end
  end

  # La ragione per cui la definizione vive in un posto solo: se il contatore avesse una query sua,
  # basterebbe una condizione diversa perché la lista dicesse 5 e la pagina Approvazioni 3.
  describe "il numero coincide con quello della pagina delle approvazioni" do
    it "contatore della lista e righe di revisione della coda dicono lo stesso numero" do
      allow_n_plus_one do
        3.times { review_ticket(reviewer: member) }
        review_ticket(reviewer: collega)
        create(:ticket, organization: org, project: project, status: open_status, reviewer: member)
      end

      get list_member_tickets_path
      dal_contatore = Capybara.string(response.body).find("[data-test='tickets-count-awaiting']").text[/\d+/].to_i

      visible_projects = Projects::Project.where(id: project.id)
      batch = Home::Approvals::Queue.call(account: member, organization: org,
                                          visible_projects: visible_projects,
                                          visible_tickets: Ticketing::Ticket.where(project_id: project.id))
      dalla_coda = batch.items.count { |item| item.kind == :review }

      expect(dal_contatore).to eq(3)
      expect(dal_contatore).to eq(dalla_coda)
    end
  end
end
