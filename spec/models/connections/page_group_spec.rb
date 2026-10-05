# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::PageGroup, type: :model do
  let(:organization) { create(:organization) }
  let(:page) do
    create(:knowledge_page, organization: organization, project: create(:project, organization: organization))
  end

  it "impedisce di collegare due volte lo stesso gruppo alla pagina" do
    group = create(:group, organization: organization)
    described_class.create!(page: page, group: group)
    duplicate = described_class.new(page: page, group: group)

    expect(duplicate).to be_invalid
    expect(duplicate.errors[:group_id]).to be_present
  end

  it "rifiuta un gruppo di un'altra organizzazione (tenant-integrity via page.organization)" do
    foreign_group = create(:group) # altra org
    link = described_class.new(page: page, group: foreign_group)

    expect(link).to be_invalid
    expect(link.errors[:group]).to be_present
  end

  it "accetta un gruppo della stessa organizzazione della pagina" do
    group = create(:group, organization: organization)
    expect(described_class.new(page: page, group: group)).to be_valid
  end
end
