# frozen_string_literal: true

require "rails_helper"

# Guidance area member (CYRA-75): CRUD dei tre livelli dal web + preview del contesto effettivo del
# progetto con origine e override espliciti (Scenario 2). rack_test: il drag di riordino (JS) non è
# guidato qui — la sua persistenza è coperta dal request spec (reorder).
RSpec.describe "Member guidance", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:group) { create(:group, organization: org, name: "Platform") }
  let(:project) { create(:project, organization: org, group: group) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def owner_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  it "l'owner crea un riferimento locale dal progetto" do
    sign_in_as(owner_account)
    visit member_project_guidance_path(project)
    click_on_test "guidance-reference-add"
    expect_test "guidance-reference-form"

    fill_test "guidance-reference-key", with: "app-repo"
    fill_test "guidance-reference-location", with: "git@github.com:acme/app.git"
    click_on_test "guidance-reference-submit"

    expect_test "flash-notice"
    expect(page).to have_css("[data-test^='guidance-reference-row-']")
    expect(project.guidance_references.where(key: "app-repo")).to exist
  end

  it "l'owner crea una procedura locale dal progetto" do
    sign_in_as(owner_account)
    visit new_member_project_guidance_procedure_path(project)

    fill_test "guidance-procedure-key", with: "setup"
    fill_test "guidance-procedure-content", with: "Installa le dipendenze"
    click_on_test "guidance-procedure-submit"

    expect(project.guidance_procedures.where(key: "setup")).to exist
  end

  it "l'owner elimina un riferimento locale (la modifica resta nel livello)" do
    reference = create(:guidance_reference, owner: project, key: "old")
    sign_in_as(owner_account)
    visit member_project_guidance_path(project)
    # il button_to delete vive in un <details> (kebab): rack_test lo considera nascosto → visible: :all
    find("[data-test='guidance-reference-delete-#{reference.id}']", visible: :all).click

    expect(project.guidance_references.where(key: "old")).not_to exist
  end

  it "la preview del progetto rende origine e override espliciti (Scenario 2)" do
    create(:guidance_reference, owner: org, key: "repo", location: "git@org")
    create(:guidance_reference, owner: project, key: "repo", location: "git@project")
    sign_in_as(owner_account)

    visit member_project_guidance_path(project)

    expect_test "guidance-preview"
    within("[data-test='guidance-preview-reference-repo']") do
      expect(page).to have_text("git@project")
      expect(page).to have_text(I18n.t("member.guidance.status.overridden"))
      expect(page).to have_text(I18n.t("member.guidance.origin.project"))
    end
  end

  it "l'owner gestisce la guidance a livello organizzazione" do
    sign_in_as(owner_account)
    visit member_organization_guidance_path
    click_on_test "guidance-reference-add"

    fill_test "guidance-reference-key", with: "org-repo"
    fill_test "guidance-reference-location", with: "git@org"
    click_on_test "guidance-reference-submit"
    conferma_azione_pericolosa

    expect(org.guidance_references.where(key: "org-repo")).to exist
  end

  it "l'owner gestisce la guidance a livello gruppo dal bottone dell'header" do
    sign_in_as(owner_account)
    visit member_group_path(group)
    click_on_test "group-guidance"
    expect_test "member-group-guidance"

    click_on_test "guidance-procedure-add"
    fill_test "guidance-procedure-key", with: "group-setup"
    fill_test "guidance-procedure-content", with: "Regole del gruppo"
    click_on_test "guidance-procedure-submit"

    expect(group.guidance_procedures.where(key: "group-setup")).to exist
  end

  # CYRA-576: la spiegazione era una sola, scritta dal punto di vista del progetto, ed era mostrata
  # identica ai tre livelli — sull'organizzazione diceva che l'organizzazione eredita da sé stessa.
  describe "la spiegazione del livello (CYRA-576)" do
    # CYRA-883 — the explanation is the header subtitle.
    def spiegazione_del_titolo
      find("[data-test='page-header-subtitle']").text
    end

    it "l'organizzazione dice cosa vale per tutta l'organizzazione, non che eredita da sé stessa (Scenario 1)" do
      sign_in_as(owner_account)
      visit member_organization_guidance_path

      expect(spiegazione_del_titolo).to include(I18n.t("member.guidance.help.organization"))
    end

    it "il gruppo dice che eredita dall'organizzazione e scende ai suoi progetti" do
      sign_in_as(owner_account)
      visit member_group_guidance_path(group)

      expect(spiegazione_del_titolo).to include(I18n.t("member.guidance.help.group"))
    end
  end

  # CYRA-576 Scenario 2: il modulo non diceva mai a quale livello si stesse scrivendo — l'unico
  # indizio era l'indirizzo della pagina.
  describe "il modulo dichiara il livello (CYRA-576)" do
    it "la nuova procedura dice livello e nome ai tre livelli" do
      sign_in_as(owner_account)

      visit new_member_organization_guidance_procedure_path
      expect(page).to have_text(I18n.t("member.guidance.applies_to.organization", name: org.name))

      visit new_member_group_guidance_procedure_path(group)
      expect(page).to have_text(I18n.t("member.guidance.applies_to.group", name: group.name))

      visit new_member_project_guidance_procedure_path(project)
      expect(page).to have_text(I18n.t("member.guidance.applies_to.project", name: project.name))
    end

    it "il nuovo riferimento dice livello e nome ai tre livelli" do
      sign_in_as(owner_account)

      visit new_member_organization_guidance_reference_path
      expect(page).to have_text(I18n.t("member.guidance.applies_to.organization", name: org.name))

      visit new_member_group_guidance_reference_path(group)
      expect(page).to have_text(I18n.t("member.guidance.applies_to.group", name: group.name))

      visit new_member_project_guidance_reference_path(project)
      expect(page).to have_text(I18n.t("member.guidance.applies_to.project", name: project.name))
    end

    it "la modifica di una procedura dichiara il livello del progetto" do
      procedure = create(:guidance_procedure, owner: project, key: "setup")
      sign_in_as(owner_account)

      visit edit_member_project_guidance_procedure_path(project, procedure)

      expect(page).to have_text(I18n.t("member.guidance.applies_to.project", name: project.name))
      expect(page).to have_text(I18n.t("member.guidance.home.project", name: project.name))
    end
  end
end
