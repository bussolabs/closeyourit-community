# frozen_string_literal: true

require "rails_helper"

# CYRA-555 — cercare qualcosa che non c'è faceva dire agli elenchi che i dati NON ESISTONO: «Ancora
# nessuna idea» con cinquanta idee dichiarate in alto, «Ancora nessun team» con sei team in casa,
# «Niente qui» sotto una colonna che dichiarava centotrentuno ticket. E nessuna di quelle schermate
# offriva di togliere il filtro: bisognava svuotare il campo a mano o riscrivere l'indirizzo.
#
# Qui il contratto, uguale su ogni elenco: a zero corrispondenze si legge che è la RICERCA a non aver
# trovato niente (marker `*-no-results`), c'è sempre il modo di azzerarla (`*-reset-search`), e il
# messaggio di elenco DAVVERO vuoto (`*-empty`) resta un'altra cosa.
#
# Ramo testuale ovunque (`semantic: "0"` dove la ricerca semantica è la predefinita): i test non
# devono dipendere dal servizio embedding.
RSpec.describe "Elenchi filtrati senza corrispondenze (CYRA-555)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def html = Capybara.string(response.body)

  # Il contratto in una riga: cercato senza esito → «nessuna corrispondenza» + azzera, MAI l'empty.
  def expect_no_results(prefix)
    expect(html).to have_css("[data-test='#{prefix}-no-results']")
    expect(html).to have_css("[data-test='#{prefix}-reset-search']")
    expect(html).not_to have_css("[data-test='#{prefix}-empty']")
  end

  # E il suo rovescio: elenco davvero vuoto → il messaggio che spiega a cosa serve, MAI il primo.
  def expect_empty(prefix)
    expect(html).to have_css("[data-test='#{prefix}-empty']")
    expect(html).not_to have_css("[data-test='#{prefix}-no-results']")
  end

  describe "Idee" do
    before { create(:project_membership, account: owner, project: project) }

    it "una ricerca senza esito dice che nessuna idea corrisponde, e offre di azzerarla (Scenario 1)" do
      create(:idea, organization: org, project: project, title: "Esportare i report")
      sign_in(owner)

      get member_ideas_path, params: { q: "zqxwvbnm", semantic: "0" }

      expect_no_results("ideas")
      expect(response.body).to include("zqxwvbnm")
    end

    it "a zero corrispondenze i chip contano le idee reali, non zero" do
      create(:idea, organization: org, project: project, title: "Esportare i report")
      sign_in(owner)

      get member_ideas_path, params: { q: "zqxwvbnm", semantic: "0" }

      expect(html).to have_css("[data-test='ideas-count-total']", text: "1")
    end

    it "senza idee e senza filtri resta il messaggio di benvenuto (Scenario 2)" do
      sign_in(owner)

      get member_ideas_path

      expect_empty("ideas")
    end
  end

  describe "Bacheca dei ticket" do
    let(:status) { create(:ticket_status, organization: org) }

    before { create(:project_membership, account: owner, project: project) }

    it "una ricerca senza esito lo dichiara nelle colonne, invece di «Niente qui» (Scenario 1)" do
      create(:ticket, organization: org, project: project, status: status, title: "Un ticket vero")
      sign_in(owner)

      get member_tickets_path, params: { q: "zqxwvbnm", semantic: "0" }

      expect(html).to have_css("[data-test='board-column-no-results']")
      expect(html).to have_css("[data-test='board-reset-search']")
      expect(html).not_to have_css("[data-test='board-column-empty']")
    end

    it "senza ricerca la colonna vuota resta quella di sempre (Scenario 2)" do
      status # la bacheca ha colonne solo se l'organizzazione ha stati attivi
      sign_in(owner)

      get member_tickets_path

      expect(html).to have_css("[data-test='board-column-empty']")
      expect(html).not_to have_css("[data-test='board-column-no-results']")
    end

    it "a zero corrispondenze il conteggio della colonna resta il totale reale dello stato" do
      create(:ticket, organization: org, project: project, status: status, title: "Un ticket vero")
      sign_in(owner)

      get member_tickets_path, params: { q: "zqxwvbnm", semantic: "0" }

      expect(html).to have_css("[data-test='board-stat-tickets']", text: "1")
    end
  end

  describe "Vulnerabilità" do
    def finding_in(target_project)
      manifest = create(:vulnerability_manifest, project: target_project)
      package = create(:vulnerability_package, manifest: manifest, name: "rails", version: "7.0.0")
      create(:vulnerability_finding, project: target_project, package: package,
                                     advisory: create(:vulnerability_advisory, severity: :high))
    end

    it "una ricerca senza esito non dice più che non ci sono vulnerabilità (Scenario 1)" do
      finding_in(project)
      sign_in(owner)

      get member_monitoring_vulnerabilities_path, params: { q: "zqxwvbnm" }

      expect_no_results("vulnerabilities")
    end

    it "senza vulnerabilità e senza filtri resta il messaggio «tutto a posto» (Scenario 2)" do
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      expect_empty("vulnerabilities")
    end
  end

  describe "Raccolte della conoscenza" do
    before { create(:project_membership, account: owner, project: project) }

    it "una ricerca senza esito dice che nessuna raccolta corrisponde (Scenario 1)" do
      create(:knowledge_book, organization: org, project: project, title: "Manuale onboarding")
      sign_in(owner)

      get member_knowledge_books_path, params: { q: "zqxwvbnm" }

      expect_no_results("knowledge-books")
    end

    it "senza raccolte e senza filtri resta il messaggio di benvenuto (Scenario 2)" do
      sign_in(owner)

      get member_knowledge_books_path

      expect_empty("knowledge-books")
    end
  end

  describe "Team" do
    it "una ricerca senza esito dice che nessun team corrisponde, e offre di azzerarla (Scenario 1)" do
      create(:team, organization: org, name: "Squadra rilascio")
      sign_in(owner)

      get member_teams_path, params: { q: "zqxwvbnm" }

      expect_no_results("teams")
    end

    it "a zero corrispondenze il chip conta i team reali, non zero" do
      create(:team, organization: org, name: "Squadra rilascio")
      sign_in(owner)

      get member_teams_path, params: { q: "zqxwvbnm" }

      expect(html).to have_css("[data-test='teams-count-teams']", text: "1")
    end

    it "senza team e senza ricerca resta il messaggio di elenco vuoto (Scenario 2)" do
      sign_in(owner)

      get member_teams_path

      expect_empty("teams")
    end
  end

  describe "Ruoli" do
    it "una ricerca senza esito dice che nessun ruolo corrisponde (Scenario 1)" do
      create(:role, organization: org, name: "Revisore")
      sign_in(owner)

      get member_roles_path, params: { q: "zqxwvbnm" }

      expect_no_results("roles")
    end

    it "a zero corrispondenze il chip conta i ruoli reali, non zero" do
      create(:role, organization: org, name: "Revisore")
      sign_in(owner)

      get member_roles_path, params: { q: "zqxwvbnm" }

      expect(html).to have_css("[data-test='roles-count-roles']", text: "1")
    end
  end

  describe "Membri" do
    it "una ricerca senza esito non lascia più la tabella muta (Scenario 1)" do
      sign_in(owner)

      get member_members_path, params: { q: "zqxwvbnm" }

      expect(html).to have_css("[data-test='members-no-results']")
      expect(html).to have_css("[data-test='members-reset-search']")
    end

    it "a zero corrispondenze il chip conta le persone reali, non zero" do
      sign_in(owner)

      get member_members_path, params: { q: "zqxwvbnm" }

      expect(html).to have_css("[data-test='members-count-members']", text: "1")
    end

    it "senza ricerca la tabella dei membri resta al suo posto (Scenario 2)" do
      sign_in(owner)

      get member_members_path

      expect(html).not_to have_css("[data-test='members-no-results']")
      expect(html).to have_css("[data-test='member-membership-row'], tbody tr")
    end
  end
end
