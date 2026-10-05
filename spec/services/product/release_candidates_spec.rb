# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product::ReleaseCandidates, type: :service do
  let(:organization) { create(:organization) }
  let(:group) { create(:group, organization: organization) }
  let(:platform) { create(:platform, organization: organization) }

  # Progetto del prodotto che dichiara la piattaforma: solo le sue release sono indicabili.
  def project_on_platform(target_platform: platform, target_group: group)
    create(:project, organization: organization, group: target_group).tap do |project|
      Connections::ProjectPlatform.create!(project: project, platform: target_platform)
    end
  end

  it "ritorna vuoto quando il prodotto non ha progetti su quella piattaforma" do
    expect(described_class.for(group: group, platform: platform)).to be_empty
  end

  it "esclude i progetti fuori dal prodotto" do
    outsider = create(:project, organization: organization)
    Connections::ProjectPlatform.create!(project: outsider, platform: platform)
    create(:release, project: outsider)

    expect(described_class.for(group: group, platform: platform)).to be_empty
  end

  it "esclude i progetti del prodotto che non girano su quella piattaforma" do
    project = create(:project, organization: organization, group: group)
    create(:release, project: project)

    expect(described_class.for(group: group, platform: platform)).to be_empty
  end

  it "preferisce le release di produzione" do
    project = project_on_platform
    production = create(:release, project: project, version: "1.0.0", environment: "production")
    create(:release, project: project, version: "1.1.0", environment: "staging")

    expect(described_class.for(group: group, platform: platform)).to contain_exactly(production)
  end

  it "ricade su tutti gli ambienti per il solo progetto senza release di produzione" do
    with_production = project_on_platform
    production = create(:release, project: with_production, version: "1.0.0", environment: "production")
    create(:release, project: with_production, version: "1.1.0", environment: "staging")

    without_production = project_on_platform
    staging_only = create(:release, project: without_production, version: "0.9.0", environment: "staging")

    expect(described_class.for(group: group, platform: platform)).to contain_exactly(production, staging_only)
  end

  it "mette per prima la release che gira ora" do
    project = project_on_platform
    create(:release, project: project, version: "1.0.0", deployed_at: 2.days.ago)
    live = create(:release, project: project, version: "0.1.0", current: true, deployed_at: 10.days.ago)

    expect(described_class.for(group: group, platform: platform).first).to eq(live)
  end

  it "ordina per data anche quando deployed_at non è valorizzato" do
    project = project_on_platform
    older = create(:release, project: project, version: "1.0.0", created_at: 3.days.ago)
    newer = create(:release, project: project, version: "2.0.0", created_at: 1.day.ago)

    expect(described_class.for(group: group, platform: platform)).to eq([ newer, older ])
  end

  it "include sempre la versione già indicata, anche oltre il limite" do
    project = project_on_platform
    3.times { |i| create(:release, project: project, version: "1.0.#{i}") }
    selected = create(:release, project: project, version: "0.0.1", created_at: 2.years.ago)

    candidates = described_class.for(group: group, platform: platform, limit: 2, selected: selected)

    expect(candidates).to include(selected)
  end

  it "non duplica la versione indicata se è già tra i candidati" do
    project = project_on_platform
    selected = create(:release, project: project, version: "1.0.0")

    candidates = described_class.for(group: group, platform: platform, selected: selected)

    expect(candidates.count { |r| r.id == selected.id }).to eq(1)
  end

  it "ritorna la sola versione indicata quando il prodotto non ha progetti su quella piattaforma" do
    orphan = create(:release, project: create(:project, organization: organization))

    expect(described_class.for(group: group, platform: platform, selected: orphan)).to eq([ orphan ])
  end

  it "rispetta il limite" do
    project = project_on_platform
    3.times { |i| create(:release, project: project, version: "1.0.#{i}") }

    expect(described_class.for(group: group, platform: platform, limit: 2).size).to eq(2)
  end
end
