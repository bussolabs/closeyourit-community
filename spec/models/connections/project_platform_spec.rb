# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::ProjectPlatform, type: :model do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  it "è valida quando project e platform sono nella stessa org" do
    platform = create(:platform, organization: org)
    expect(described_class.new(project: project, platform: platform)).to be_valid
  end

  it "rifiuta una platform di un'altra org (integrità tenant)" do
    foreign = create(:platform, organization: create(:organization))
    link = described_class.new(project: project, platform: foreign)
    expect(link).not_to be_valid
    expect(link.errors[:platform]).to be_present
  end

  it "rifiuta lo stesso platform due volte sullo stesso progetto" do
    platform = create(:platform, organization: org)
    project.platforms << platform
    dup = described_class.new(project: project, platform: platform)
    expect(dup).not_to be_valid
  end

  it "guard tenant: non solleva quando project/platform sono assenti" do
    # Esercita il return del guard difensivo blank? in platform_matches_project_organization.
    expect { described_class.new.valid? }.not_to raise_error
  end
end
