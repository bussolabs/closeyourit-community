# frozen_string_literal: true

require "rails_helper"

# CYRA-177: gemello service-side del concern KnowledgePageManagement — chi può gestire una pagina KB
# con l'account reale dell'attore (nessuna impersonation).
RSpec.describe Knowledge::PageManageable do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  def member!(account, role = :member) = create(:membership, account: account, organization: org, role: role)

  it "l'autore gestisce la propria pagina se ne vede tutti i progetti effettivi" do
    author = create(:account)
    member!(author)
    create(:project_membership, account: author, project: project)
    page = create(:knowledge_page, organization: org, project: project, created_by: author)

    expect(described_class.call(page: page, actor: author)).to be true
  end

  it "un non autore con knowledge.edit su tutti i progetti effettivi gestisce" do
    editor = create(:account)
    member!(editor)
    create(:project_membership, account: editor, project: project)
    create(:account_permission, account: editor, organization: org, permission_key: "knowledge.edit", effect: :allow)
    page = create(:knowledge_page, organization: org, project: project, created_by: create(:account))

    expect(described_class.call(page: page, actor: editor)).to be true
  end

  it "un non autore senza knowledge.edit NON gestisce" do
    viewer = create(:account)
    member!(viewer)
    create(:project_membership, account: viewer, project: project)
    page = create(:knowledge_page, organization: org, project: project, created_by: create(:account))

    expect(described_class.call(page: page, actor: viewer)).to be false
  end

  it "NON gestisce se un progetto effettivo non è visibile all'attore" do
    outsider = create(:account)
    member!(outsider)
    page = create(:knowledge_page, organization: org, project: project, created_by: create(:account))

    expect(described_class.call(page: page, actor: outsider)).to be false
  end

  it "una pagina org-wide è gestibile solo con accesso pieno (owner/god)" do
    owner = create(:account)
    member!(owner, :owner)
    plain = create(:account)
    member!(plain)
    page = create(:knowledge_page, :org_wide, organization: org, created_by: create(:account))

    expect(described_class.call(page: page, actor: owner)).to be true
    expect(described_class.call(page: page, actor: plain)).to be false
  end
end
