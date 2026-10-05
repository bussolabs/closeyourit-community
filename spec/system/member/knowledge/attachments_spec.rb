# frozen_string_literal: true

require "rails_helper"

# Allegati end-to-end dalla show della pagina (rack_test: la dropzone drag&drop è JS-only e resta
# fuori; qui il flusso server-side: carica → compare in card → rinomina → scarica → elimina).
RSpec.describe "Member knowledge — allegati", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:project) { create(:project, organization: org) }
  let!(:page_kb) { create(:knowledge_page, organization: org, project: project, created_by: owner, title: "Rilascio") }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def fixture(name)
    Rails.root.join("spec/fixtures/files/#{name}")
  end

  it "carica uno script, lo mostra marcato come tale e lo rende scaricabile" do
    sign_in_as(owner)
    visit member_knowledge_page_path(page_kb)

    expect(page).to have_selector("[data-test='knowledge-attachments-empty']")

    attach_file("files[]", fixture("script.sh"))
    click_on_test "attachment-upload-submit"

    expect(page).to have_content("script.sh")
    # Il badge dichiara all'utente che il file è solo conservato, mai eseguito.
    expect(page).to have_selector("[data-test='attachment-script-badge']")

    allegato = page_kb.attachments.sole
    expect(page).to have_selector("[data-test='attachment-download-#{allegato.id}']")
  end

  it "rifiuta una pagina web con un messaggio chiaro" do
    sign_in_as(owner)
    visit member_knowledge_page_path(page_kb)

    attach_file("files[]", fixture("payload.html"))
    click_on_test "attachment-upload-submit"

    expect(page_kb.attachments).to be_empty
    expect(page).to have_content(I18n.t("member.knowledge.attachments.errors.invalid_file"))
  end

  it "rinomina un allegato" do
    allegato = create(:knowledge_attachment, page: page_kb, created_by: owner, title: "spec.pdf")
    sign_in_as(owner)
    visit member_knowledge_page_path(page_kb)

    find("[data-test='attachment-edit-#{allegato.id}']").click
    fill_test "attachment-title", with: "Procedura di rilascio"
    click_on_test "attachment-submit"

    expect(page).to have_content("Procedura di rilascio")
    expect(allegato.reload.title).to eq("Procedura di rilascio")
  end

  it "elimina un allegato" do
    allegato = create(:knowledge_attachment, page: page_kb, created_by: owner)
    sign_in_as(owner)
    visit member_knowledge_page_path(page_kb)

    expect do
      find("[data-test='attachment-delete-#{allegato.id}']").click
    end.to change(page_kb.attachments, :count).by(-1)

    expect(page).to have_selector("[data-test='knowledge-attachments-empty']")
  end

  it "chi può solo leggere la pagina vede gli allegati ma non la dropzone" do
    lettore = create(:account)
    create(:membership, account: lettore, organization: org, role: :member)
    create(:project_membership, account: lettore, project: project)
    allegato = create(:knowledge_attachment, page: page_kb, created_by: owner)

    sign_in_as(lettore)
    visit member_knowledge_page_path(page_kb)

    expect(page).to have_selector("[data-test='attachment-download-#{allegato.id}']")
    expect(page).to have_no_selector("[data-test='attachment-upload-form']")
    expect(page).to have_no_selector("[data-test='attachment-delete-#{allegato.id}']")
  end
end
