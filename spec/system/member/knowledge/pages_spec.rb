# frozen_string_literal: true

require "rails_helper"

# CRUD Knowledge end-to-end (rack_test: il prefill template decisione è JS-only e resta fuori;
# qui il flusso server-side: crea → show markdown → cerca → filtra).
RSpec.describe "Member knowledge — pagine", type: :system do
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

  it "crea una pagina decisione e la mostra renderizzata" do
    sign_in_as(owner)
    visit new_member_knowledge_page_path

    fill_test "knowledge-form-title", with: "Scelta del database"
    # Select progetto: componente nativo sotto (rack_test) → select diretto sul name.
    find("[data-test='knowledge-form-projects']", visible: :all).find("option[value='#{project.id}']").select_option
    choose_kind = find("[data-test='knowledge-form-kind'] input[value='decision']", visible: :all)
    choose_kind.set(true)
    fill_test "knowledge-form-body", with: "## Contesto\n\nServe un DB relazionale."
    click_on_test "knowledge-form-submit"

    page_record = Knowledge::Page.find_by(title: "Scelta del database")
    expect(page_record).to be_present
    expect(page_record.kind).to eq("decision")
    expect_test "knowledge-page"
    expect(page).to have_css("[data-test='knowledge-body'] h2", text: "Contesto")

    # Colonna destra "Specifiche": presenza dei blocchi (selettori solo data-test) + valori DB/path.
    expect_test "knowledge-specs"
    within_test("knowledge-spec-project") do
      expect(page).to have_link(href: member_project_path(project))
    end
    expect_test "knowledge-spec-kind"
    # CYRA-434: lo stato è una frase leggibile, l'identificativo un bottone che lo copia.
    within_test("knowledge-spec-assistant") do
      expect(page).to have_text(I18n.t("member.knowledge.show.assistant_not_yet"))
    end
    expect_test "knowledge-spec-length"
    within_test("knowledge-spec-id") do
      expect(page).to have_no_text(page_record.id)
      expect(page).to have_button(I18n.t("member.knowledge.show.id_copy"))
    end
    expect_test "knowledge-audit"
    expect(page).to have_css("[data-test='audit-created']")
  end

  it "crea una pagina con sezione tecnica e mostra le viste Semplice e Tecnico" do
    sign_in_as(owner)
    visit new_member_knowledge_page_path

    fill_test "knowledge-form-title", with: "Con sezione tecnica"
    find("[data-test='knowledge-form-projects']", visible: :all).find("option[value='#{project.id}']").select_option
    fill_test "knowledge-form-body", with: "Spiegazione semplice per tutti."
    fill_test "knowledge-form-tech-spec", with: "## Dettagli\n\nColonna vector(1024)."
    click_on_test "knowledge-form-submit"

    page_record = Knowledge::Page.find_by(title: "Con sezione tecnica")
    # Il textarea HTML normalizza i newline a CRLF: confronto indipendente dal terminatore di riga.
    expect(page_record.tech_spec.delete("\r")).to eq("## Dettagli\n\nColonna vector(1024).")

    expect_test "knowledge-tabs"
    expect_test "knowledge-tab-simple"
    expect_test "knowledge-tab-tech"
    expect(page).to have_css("[data-test='knowledge-body']", text: "Spiegazione semplice per tutti.")
    expect(page).to have_css("[data-test='knowledge-tech'] h2", text: "Dettagli")
  end

  # CYRA-429: due livelli che portano allo stesso identico testo fanno sembrare rotto il controllo.
  it "senza sezione tecnica non c'è nessuna scelta fra i due livelli" do
    create(:knowledge_page, organization: org, project: project, created_by: owner,
                            title: "Solo semplice", body: "Testo piano e chiaro.")
    sign_in_as(owner)
    visit member_knowledge_page_path(Knowledge::Page.find_by(title: "Solo semplice"))

    expect(page).to have_css("[data-test='knowledge-body']", text: "Testo piano e chiaro.")
    expect(page).to have_no_css("[data-test='knowledge-tabs']")
    expect(page).to have_no_css("[data-test='knowledge-tab-tech']")
  end

  # CYRA-429: l'avviso parlava a chi legge, che non può correggerlo. Ora arriva a chi ha appena
  # scritto, e chi passa a leggere non se lo trova davanti.
  it "l'avviso sul linguaggio tecnico arriva a chi salva, non a chi legge" do
    sign_in_as(owner)
    visit new_member_knowledge_page_path

    fill_test "knowledge-form-title", with: "Molto tecnica"
    find("[data-test='knowledge-form-projects']", visible: :all).find("option[value='#{project.id}']").select_option
    fill_test "knowledge-form-body", with: "Il middleware espone un endpoint webhook per il deploy del backend."
    click_on_test "knowledge-form-submit"

    expect(page).to have_text(I18n.t("member.knowledge.plain_warning_author"))

    # Chi arriva dopo, sulla stessa pagina, non vede nessun avviso.
    visit member_knowledge_page_path(Knowledge::Page.find_by(title: "Molto tecnica"))
    expect(page).to have_no_text(I18n.t("member.knowledge.plain_warning_author"))
  end

  it "l'elenco dice quante pagine sono senza versione semplice" do
    create(:knowledge_page, organization: org, project: project, created_by: owner, title: "Tecnica",
                            body: "Il middleware espone un endpoint webhook per il deploy del backend.")
    create(:knowledge_page, organization: org, project: project, created_by: owner, title: "Piana",
                            body: "Come si chiede una nuova casella di posta al team.")
    sign_in_as(owner)

    visit member_knowledge_pages_path

    within_test("knowledge-count-without-simple") { expect(page).to have_text("1") }
  end

  it "index: cerca per titolo e filtra per kind via URL" do
    create(:knowledge_page, organization: org, project: project, title: "Guida deploy", kind: :guide)
    create(:knowledge_page, :decision, organization: org, project: project, title: "Decisione API")
    sign_in_as(owner)

    visit member_knowledge_pages_path
    expect(page).to have_css("[data-test='knowledge-row']", count: 2)

    fill_test "knowledge-search", with: "deploy"
    click_on_test "knowledge-filter"
    expect(page).to have_css("[data-test='knowledge-row']", count: 1)
    expect(page).to have_text("Guida deploy")

    visit member_knowledge_pages_path(kind: [ "decision" ])
    expect(page).to have_css("[data-test='knowledge-row']", count: 1)
    expect(page).to have_text("Decisione API")
  end

  # CYRA-419 Scenario 3 — «voglio rivedere le pagine non scritte da persone, senza aprirle una per una».
  it "index: isola dal filtro le pagine scritte da un assistente" do
    create(:knowledge_page, :written_by_agent, organization: org, project: project, title: "Trappola dei worktree")
    create(:knowledge_page, :written_by_human, organization: org, project: project, title: "Setup ambienti")
    sign_in_as(owner)

    visit member_knowledge_pages_path
    expect(page).to have_css("[data-test='knowledge-row']", count: 2)

    find("[data-test='filter-author'] option[value='agent']", visible: :all).select_option
    click_on_test "knowledge-filter"

    expect(page).to have_css("[data-test='knowledge-row']", count: 1)
    expect(page).to have_text("Trappola dei worktree")
    expect(page).to have_css("[data-test='knowledge-agent-badge']")
    within_test("knowledge-count-agent") { expect(page).to have_text("1") }
  end
end
