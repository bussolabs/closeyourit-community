# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::PageProject, type: :model do
  let(:organization) { create(:organization) }
  let(:page) do
    create(:knowledge_page, organization: organization, project: create(:project, organization: organization))
  end

  it "impedisce di collegare due volte lo stesso progetto alla pagina" do
    project = create(:project, organization: organization)
    described_class.create!(page: page, project: project)
    duplicate = described_class.new(page: page, project: project)

    expect(duplicate).to be_invalid
    expect(duplicate.errors[:project_id]).to be_present
  end

  it "rifiuta un progetto di un'altra organizzazione (tenant-integrity via page.organization)" do
    foreign_project = create(:project) # altra org
    link = described_class.new(page: page, project: foreign_project)

    expect(link).to be_invalid
    expect(link.errors[:project]).to be_present
  end

  it "accetta un progetto della stessa organizzazione della pagina" do
    project = create(:project, organization: organization)
    expect(described_class.new(page: page, project: project)).to be_valid
  end
end
