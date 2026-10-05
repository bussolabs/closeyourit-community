# frozen_string_literal: true

require "rails_helper"

# Coda di revisione delle pagine KB (CYRA-298, rack_test: il flusso è tutto server-side — la lettura
# della proposta è un <details> nativo, le decisioni sono due POST).
RSpec.describe "Member knowledge — revisione", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:project) { create(:project, organization: org) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "Scenario 2: accettare una proposta la fa entrare nella knowledge" do
    proposta = create(:knowledge_page, :in_review, organization: org, project: project,
                                                   title: "Trappola dei worktree")
    sign_in_as(owner)

    visit member_knowledge_reviews_path
    within_test("knowledge-review-waiting") { expect(page).to have_text("Trappola dei worktree") }

    click_on_test "knowledge-review-accept-#{proposta.id}"

    expect(page).to have_text(I18n.t("member.knowledge.reviews.approved"))
    expect(proposta.reload).to be_status_published
    # Fuori dalla coda, dentro la knowledge.
    expect(page).not_to have_css("[data-test='knowledge-review-waiting']")
    visit member_knowledge_pages_path
    expect(page).to have_text("Trappola dei worktree")
  end

  it "Scenario 3: scartare una proposta la toglie di mezzo senza cancellarla" do
    proposta = create(:knowledge_page, :in_review, organization: org, project: project,
                                                   title: "Elenco dei file toccati")
    sign_in_as(owner)

    visit member_knowledge_reviews_path
    click_on_test "knowledge-review-reject-#{proposta.id}"

    expect(page).to have_text(I18n.t("member.knowledge.reviews.rejected"))
    expect(proposta.reload).to be_status_rejected
    # Resta elencata fra le scartate, non fra quelle in attesa.
    within_test("knowledge-review-rejected") { expect(page).to have_text("Elenco dei file toccati") }
    visit member_knowledge_pages_path
    expect(page).not_to have_text("Elenco dei file toccati")
  end

  it "Scenario 1: la proposta si legge per intero senza cambiare pagina né aprire niente" do
    create(:knowledge_page, :in_review, organization: org, project: project,
                                        title: "Perché la cache sta sul registry",
                                        body: "Contesto, decisione e conseguenze.",
                                        review_note: "Decisione presa oggi, col motivo.")
    sign_in_as(owner)

    visit member_knowledge_reviews_path

    # CYRA-425 — il testo da giudicare è già davanti agli occhi: motivazione E corpo, senza toggle.
    within_test("knowledge-review-note") { expect(page).to have_text("Decisione presa oggi, col motivo.") }
    expect(page).to have_css("[data-test='knowledge-review-body']", text: "Contesto, decisione e conseguenze.")
  end

  # CYRA-425 — espandere tutto farebbe una pagina infinita: le prime tre proposte si leggono aperte,
  # dalla quarta in giù il testo resta richiuso e si apre a richiesta.
  it "Scenario 1: con una coda lunga solo le prime tre proposte sono già aperte" do
    4.times do |i|
      create(:knowledge_page, :in_review, organization: org, project: project,
                                          title: "Proposta #{i}", body: "Corpo della proposta #{i}",
                                          created_at: (i + 1).hours.ago)
    end
    sign_in_as(owner)

    visit member_knowledge_reviews_path

    # Ordine: la più recente in cima. Le tre in cima aperte, la più vecchia chiusa ma leggibile.
    expect(page).to have_css("[data-test='knowledge-review-body']", text: "Corpo della proposta 0")
    expect(page).to have_css("[data-test='knowledge-review-body']", text: "Corpo della proposta 2")
    expect(page).not_to have_css("[data-test='knowledge-review-body']", text: "Corpo della proposta 3")
    expect(page).to have_css("[data-test='knowledge-review-body']", text: "Corpo della proposta 3", visible: :all)
    expect(page).to have_text(I18n.t("member.knowledge.reviews.read_page"))
  end

  # CYRA-425 — Scenario 2 del ticket: i due bottoni dicono cosa provocano, non solo come si chiamano.
  it "Scenario 2: accanto ai bottoni è scritto cosa provoca ciascuno" do
    create(:knowledge_page, :in_review, organization: org, project: project, title: "Trappola dei worktree")
    sign_in_as(owner)

    visit member_knowledge_reviews_path

    within_test("knowledge-review-row") do
      expect_test("knowledge-review-accept-hint")
      expect_test("knowledge-review-reject-hint")
      expect(page).to have_text(I18n.t("member.knowledge.reviews.accept_hint"))
      expect(page).to have_text(I18n.t("member.knowledge.reviews.reject_hint"))
    end
  end

  # CYRA-425 — il costo dell'errore stava scritto in grigio a corpo minore, accanto al titolo della
  # sezione: ora è una riga sua, sempre visibile, nel colore del testo normale.
  it "l'avviso che le proposte restano fuori da ricerca e risposte è sempre leggibile" do
    create(:knowledge_page, :in_review, organization: org, project: project, title: "Trappola dei worktree")
    sign_in_as(owner)

    visit member_knowledge_reviews_path

    avviso = find("[data-test='knowledge-review-visibility-note']")
    expect(avviso).to have_text(I18n.t("member.knowledge.reviews.waiting_note"))
    expect(avviso[:class]).not_to include("text-gray-400")
    expect(avviso[:class]).not_to include("text-[11px]")
  end

  it "senza proposte mostra la coda vuota" do
    sign_in_as(owner)

    visit member_knowledge_reviews_path

    within_test("knowledge-review-empty") { expect(page).to have_text(I18n.t("member.knowledge.reviews.empty")) }
  end

  # CYRA-560 — la coda cresce da sola: senza pagine né ricerca, decidere sulla centesima proposta
  # voleva dire scorrere trenta schermate, e ogni decisione riportava in cima.
  describe "coda lunga (CYRA-560)" do
    # La più recente in cima: "Proposta 0" apre l'elenco, l'ultima creata lo chiude.
    def coda_di(quante)
      Array.new(quante) do |i|
        create(:knowledge_page, :in_review, organization: org, project: project,
                                            title: "Proposta #{i}", body: "Corpo #{i}",
                                            created_at: (i + 1).hours.ago)
      end
    end

    it "Scenario 1: la coda è divisa in pagine e si passa alla successiva" do
      coda_di(13)
      sign_in_as(owner)

      visit member_knowledge_reviews_path

      expect(page).to have_text("Proposta 0")
      expect(page).to have_no_text("Proposta 12")

      within_test("knowledge-review-pagination") { click_link "2" }

      expect(page).to have_text("Proposta 12")
    end

    it "Scenario 1: si cerca una proposta per titolo" do
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Trappola dei worktree")
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Come si scrive una guida")
      sign_in_as(owner)

      visit member_knowledge_reviews_path
      fill_test "knowledge-review-search", with: "Trappola"
      click_on_test "knowledge-review-filter"

      expect(page).to have_text("Trappola dei worktree")
      expect(page).to have_no_text("Come si scrive una guida")
    end

    it "Scenario 1: la ricerca a vuoto non dice che la coda è vuota" do
      coda_di(3)
      sign_in_as(owner)

      visit member_knowledge_reviews_path(q: "niente-che-esista")

      within_test("knowledge-review-no-results") do
        expect(page).to have_text(I18n.t("member.knowledge.reviews.no_results_body", count: 3))
      end
      expect(page).to have_no_text(I18n.t("member.knowledge.reviews.empty"))
    end

    it "Scenario 2: dopo aver accettato resto sulla pagina dove ero" do
      proposte = coda_di(13)
      sign_in_as(owner)

      visit member_knowledge_reviews_path(page: 2)
      # In fondo alla coda: la proposta più vecchia, l'unica della seconda pagina.
      click_on_test "knowledge-review-accept-#{proposte.last.id}"

      expect(page).to have_text(I18n.t("member.knowledge.reviews.approved"))
      expect(current_url).to include("page=2")
    end
  end
  # CYRA-817 — le accettate che aspettano di finire nei documenti erano stampate tutte insieme: da
  # sole una quarantina di schermate, con gli scarti spinti in fondo e nessun modo di cercarne una.
  describe "da archiviare (CYRA-817)" do
    # La più recente in cima: "Da archiviare 0" apre l'elenco, l'ultima accettata lo chiude.
    def da_archiviare(quante)
      Array.new(quante) do |i|
        create(:knowledge_page, organization: org, project: project,
                                title: "Da archiviare #{i}", reviewed_at: (i + 1).hours.ago)
      end
    end

    it "Scenario 1: l'elenco è diviso in pagine e si passa alla successiva" do
      da_archiviare(13)
      sign_in_as(owner)

      visit member_knowledge_reviews_path

      expect(page).to have_text("Da archiviare 0")
      expect(page).to have_no_text("Da archiviare 12")

      within_test("knowledge-review-to-file-pagination") { click_link "2" }

      expect(page).to have_text("Da archiviare 12")
    end

    it "Scenario 1: si cerca una pagina da archiviare per titolo" do
      create(:knowledge_page, organization: org, project: project,
                              title: "Trappola dei worktree", reviewed_at: Time.current)
      create(:knowledge_page, organization: org, project: project,
                              title: "Come si scrive una guida", reviewed_at: 1.hour.ago)
      sign_in_as(owner)

      visit member_knowledge_reviews_path
      fill_test "knowledge-review-to-file-search", with: "Trappola"
      click_on_test "knowledge-review-to-file-apply"

      expect(page).to have_text("Trappola dei worktree")
      expect(page).to have_no_text("Come si scrive una guida")
    end

    # La coda in cima è un'altra cosa e resta dov'era: cercare qui non la filtra e non la svuota.
    it "Scenario 1: cercare fra le accettate non tocca la coda delle proposte" do
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta in attesa")
      create(:knowledge_page, organization: org, project: project,
                              title: "Trappola dei worktree", reviewed_at: Time.current)
      sign_in_as(owner)

      visit member_knowledge_reviews_path
      fill_test "knowledge-review-to-file-search", with: "Trappola"
      click_on_test "knowledge-review-to-file-apply"

      within_test("knowledge-review-waiting") { expect(page).to have_text("Proposta in attesa") }
    end

    it "Scenario 1: dai conteggi in alto si arriva direttamente agli scarti" do
      create(:knowledge_page, :rejected, organization: org, project: project, title: "Nota scartata")
      da_archiviare(1)
      sign_in_as(owner)

      visit member_knowledge_reviews_path

      expect(find("[data-test='knowledge-review-stat-rejected']")[:href]).to end_with("#knowledge-review-rejected")
      expect(find("[data-test='knowledge-review-stat-to-file']")[:href]).to end_with("#knowledge-review-to-file")
      expect(page).to have_css("#knowledge-review-rejected")
    end
  end
end
