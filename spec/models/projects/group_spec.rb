# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Group, type: :model do
  it "usa la tabella prefissata projects_groups" do
    expect(described_class.table_name).to eq("projects_groups")
  end

  it "è valida con nome e organizzazione" do
    expect(build(:group)).to be_valid
  end

  it "richiede il nome" do
    g = build(:group, name: "  ")
    expect(g).not_to be_valid
    expect(g.errors[:name]).to be_present
  end

  it "normalizza il nome con strip" do
    expect(create(:group, name: "  DriverOne  ").name).to eq("DriverOne")
  end

  describe "cancellazione (dependent: :nullify)" do
    let(:org) { create(:organization) }
    let(:group) { create(:group, organization: org) }

    it "alla destroy i progetti del gruppo sopravvivono e restano senza gruppo" do
      project = create(:project, organization: org, group: group)

      expect { group.destroy }.not_to change(Projects::Project, :count)
      expect(project.reload.group_id).to be_nil
    end

    it "alla destroy rimuove le sue group_memberships" do
      create(:group_membership, group: group)

      expect { group.destroy }.to change(Connections::GroupMembership, :count).by(-1)
    end
  end

  describe "color shared with its projects" do
    let(:organization) { create(:organization) }
    let(:group) { create(:group, organization:, color: "emerald") }

    it "repaints its projects when its color changes" do
      project = create(:project, organization:, group:)
      outsider = create(:project, organization:, color: "violet")

      group.update!(color: "rose")

      expect(project.reload.color).to eq("rose")
      expect(outsider.reload.color).to eq("violet")
    end

    it "leaves the projects as they are when it loses its color" do
      project = create(:project, organization:, group:)

      group.update!(color: nil)

      expect(project.reload.color).to eq("emerald")
    end
  end
end
