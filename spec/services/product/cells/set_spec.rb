# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product::Cells::Set, type: :service do
  let(:organization) { create(:organization) }
  let(:group) { create(:group, organization: organization) }
  let(:platform) { create(:platform, organization: organization) }
  let(:project) do
    create(:project, organization: organization, group: group).tap do |p|
      Connections::ProjectPlatform.create!(project: p, platform: platform)
    end
  end
  let(:category) { create(:product_category, group: group, organization: organization) }
  let(:feature) { create(:product_feature, category: category, organization: organization) }
  let(:status) { create(:feature_status, :available, organization: organization) }
  let(:actor) { create(:account) }

  it "crea la cella con stato e versione" do
    release = create(:release, project: project)
    result = described_class.call(feature: feature, platform: platform, status_id: status.id,
                                  release_id: release.id, actor: actor)

    expect(result).to be_ok
    expect(result.value.status).to eq(status)
    expect(result.value.release).to eq(release)
    expect(result.value.created_by).to eq(actor)
  end

  it "aggiorna la cella esistente invece di crearne una seconda" do
    described_class.call(feature: feature, platform: platform, status_id: status.id, actor: actor)
    other = create(:feature_status, :in_development, organization: organization)

    expect do
      described_class.call(feature: feature, platform: platform, status_id: other.id, actor: actor)
    end.not_to change(Connections::FeaturePlatform, :count)
    expect(Connections::FeaturePlatform.find_by(feature: feature, platform: platform).status).to eq(other)
  end

  it "non riscrive created_by quando la cella viene aggiornata" do
    described_class.call(feature: feature, platform: platform, status_id: status.id, actor: actor)
    described_class.call(feature: feature, platform: platform, status_id: status.id, actor: create(:account))

    expect(Connections::FeaturePlatform.find_by(feature: feature, platform: platform).created_by).to eq(actor)
  end

  it "salva senza versione: lo stato dice disponibile ma la versione non è indicata" do
    result = described_class.call(feature: feature, platform: platform, status_id: status.id, actor: actor)

    expect(result).to be_ok
    expect(result.value).to be_release_missing
  end

  it "stacca la versione quando la funzionalità torna a uno stato non rilasciato" do
    release = create(:release, project: project)
    described_class.call(feature: feature, platform: platform, status_id: status.id,
                         release_id: release.id, actor: actor)
    in_development = create(:feature_status, :in_development, organization: organization)

    result = described_class.call(feature: feature, platform: platform, status_id: in_development.id,
                                  release_id: release.id, actor: actor)

    expect(result).to be_ok
    expect(result.value.release).to be_nil
  end

  it "accetta la versione già indicata anche se il limite dei candidati la taglierebbe fuori" do
    # Un progetto con ingest attivo accumula centinaia di release: senza questo, ri-salvare una
    # cella vecchia darebbe 404 o le cancellerebbe la versione.
    old_release = create(:release, project: project, version: "0.0.1", created_at: 2.years.ago)
    cell = create(:feature_platform, feature: feature, platform: platform, status: status, release: old_release)
    5.times { |i| create(:release, project: project, version: "9.9.#{i}") }
    stub_const("Product::ReleaseCandidates::LIMIT", 2)

    result = described_class.call(feature: feature, platform: platform, status_id: status.id,
                                  release_id: old_release.id, actor: actor)

    expect(result).to be_ok
    expect(cell.reload.release).to eq(old_release)
  end

  it "rifiuta uno stato di un'altra organizzazione" do
    foreign = create(:feature_status, organization: create(:organization))
    result = described_class.call(feature: feature, platform: platform, status_id: foreign.id, actor: actor)

    expect(result).to be_err
    expect(result.error.code).to eq("R404-PRODUCT-001")
  end

  it "rifiuta uno stato disattivato" do
    inactive = create(:feature_status, :inactive, organization: organization)
    result = described_class.call(feature: feature, platform: platform, status_id: inactive.id, actor: actor)

    expect(result).to be_err
    expect(result.error.code).to eq("R404-PRODUCT-001")
  end

  it "rifiuta una versione di un progetto fuori dal prodotto" do
    outsider = create(:project, organization: organization)
    Connections::ProjectPlatform.create!(project: outsider, platform: platform)
    result = described_class.call(feature: feature, platform: platform, status_id: status.id,
                                  release_id: create(:release, project: outsider).id, actor: actor)

    expect(result).to be_err
    expect(result.error.code).to eq("R404-PRODUCT-001")
  end

  it "rifiuta una versione di un progetto che non gira su quella piattaforma" do
    other_platform = create(:platform, organization: organization)
    result = described_class.call(feature: feature, platform: other_platform, status_id: status.id,
                                  release_id: create(:release, project: project).id, actor: actor)

    expect(result).to be_err
    expect(result.error.code).to eq("R404-PRODUCT-001")
  end
end
