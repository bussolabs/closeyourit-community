# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product::MatrixColumns, type: :service do
  let(:organization) { create(:organization) }
  let(:group) { create(:group, organization: organization) }

  it "ritorna le piattaforme dichiarate dai progetti del prodotto" do
    platform = create(:platform, organization: organization)
    project = create(:project, organization: organization, group: group)
    Connections::ProjectPlatform.create!(project: project, platform: platform)

    expect(described_class.for(group: group)).to contain_exactly(platform)
  end

  it "esclude le piattaforme dichiarate solo da progetti di altri prodotti" do
    platform = create(:platform, organization: organization)
    outsider = create(:project, organization: organization)
    Connections::ProjectPlatform.create!(project: outsider, platform: platform)

    expect(described_class.for(group: group)).to be_empty
  end

  it "esclude le piattaforme disattivate che nessuna cella usa" do
    platform = create(:platform, organization: organization, active: false)
    project = create(:project, organization: organization, group: group)
    Connections::ProjectPlatform.create!(project: project, platform: platform)

    expect(described_class.for(group: group)).to be_empty
  end

  it "include una piattaforma senza progetti se una cella la usa già" do
    # È il caso che rende la matrice utile in anticipo: l'app iPhone non esiste ancora ma la
    # funzionalità è già pianificata su iOS.
    planned = create(:platform, organization: organization)
    category = create(:product_category, group: group, organization: organization)
    feature = create(:product_feature, category: category, organization: organization)
    create(:feature_platform, feature: feature, platform: planned,
                              status: create(:feature_status, organization: organization))

    expect(described_class.for(group: group)).to contain_exactly(planned)
  end

  it "mantiene come colonna una piattaforma disattivata che ha già celle" do
    platform = create(:platform, organization: organization)
    category = create(:product_category, group: group, organization: organization)
    feature = create(:product_feature, category: category, organization: organization)
    create(:feature_platform, feature: feature, platform: platform,
                              status: create(:feature_status, organization: organization))
    platform.update!(active: false)

    expect(described_class.for(group: group)).to contain_exactly(platform)
  end

  it "ordina le colonne per position" do
    first = create(:platform, organization: organization, position: 0)
    second = create(:platform, organization: organization, position: 1)
    project = create(:project, organization: organization, group: group)
    Connections::ProjectPlatform.create!(project: project, platform: second)
    Connections::ProjectPlatform.create!(project: project, platform: first)

    expect(described_class.for(group: group)).to eq([ first, second ])
  end
end
