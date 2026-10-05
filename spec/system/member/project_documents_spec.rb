# frozen_string_literal: true

require "rails_helper"

# Tab Documenti di un progetto.
# NOTA: rack_test (nessun driver JS) → il comportamento Stimulus (auto-submit on change, dropzone
# drag&drop) NON è eseguibile qui; si verifica il cablaggio DOM + il fallback no-JS (selezione file
# + click "Carica" → upload reale) e i gate di permesso.
RSpec.describe "Member project documents", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:owner) { create(:account, name: "Olivia Lane") }
  let(:member) { create(:account, name: "Milo Reed") }
  let(:project) { create(:project, organization: org, name: "Storefront") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "owner: carica un file dalla tab (fallback no-JS) e vede la riga" do
    sign_in_as(owner)
    visit member_project_documents_path(project)

    expect(page).to have_css("form[data-test='document-upload-form']")
    attach_file "project-document-input", Rails.root.join("spec/fixtures/files/notes.txt").to_s
    click_on_test "document-upload-submit"

    document = project.documents.last
    expect(document.title).to eq("notes.txt")
    expect(page).to have_css("[data-test='document-row-#{document.id}']")
  end

  it "owner: rinomina e tagga un documento via edit" do
    document = create(:document, project: project, title: "Vecchio nome")
    sign_in_as(owner)
    visit edit_member_project_document_path(project, document)

    fill_test "document-title", with: "Contratto 2026"
    fill_test "document-tags", with: "legal, q3"
    click_on_test "document-submit"

    document.reload
    expect(document.title).to eq("Contratto 2026")
    expect(document.tags).to eq(%w[legal q3])
  end

  it "owner: filtra la lista per tag" do
    legal = create(:document, project: project, title: "Contratto", tags: %w[legal])
    spec = create(:document, project: project, title: "Specifiche", tags: %w[spec])
    sign_in_as(owner)

    visit member_project_documents_path(project, tag: [ "legal" ])
    expect(page).to have_css("[data-test='document-row-#{legal.id}']")
    expect(page).to have_no_css("[data-test='document-row-#{spec.id}']")
  end

  it "owner: elimina un documento" do
    document = create(:document, project: project)
    sign_in_as(owner)
    visit member_project_documents_path(project)

    # Delete opens a <dialog> (no JS under rack_test): its red button is reached with visible: :all (F16).
    expect do
      find("[data-test='document-delete-dialog-#{document.id}-confirm']", visible: :all).click
    end.to change(project.documents, :count).by(-1)
  end

  it "member senza documents.manage: vede la tab e il download, ma non dropzone né menu riga" do
    document = create(:document, project: project)
    sign_in_as(member)
    visit member_project_documents_path(project)

    expect(page).to have_css("[data-test='project-documents-link']")
    expect(page).to have_css("[data-test='document-download-#{document.id}']")
    expect(page).to have_no_css("form[data-test='document-upload-form']")
    expect(page).to have_no_css("[data-test='document-edit-#{document.id}']", visible: :all)
    expect(page).to have_no_css("[data-test='document-delete-#{document.id}']", visible: :all)
  end
end
