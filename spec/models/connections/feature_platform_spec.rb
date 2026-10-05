# frozen_string_literal: true

require "rails_helper"

RSpec.describe Connections::FeaturePlatform, type: :model do
  # Prodotto completo: un gruppo con un progetto che dichiara una piattaforma e ha una release.
  # È lo scenario in cui "disponibile dalla 2.1.0" ha senso.
  def build_product(organization: create(:organization))
    group = create(:group, organization: organization)
    platform = create(:platform, organization: organization)
    project = create(:project, organization: organization, group: group)
    Connections::ProjectPlatform.create!(project: project, platform: platform)
    category = create(:product_category, group: group, organization: organization)
    feature = create(:product_feature, category: category, organization: organization)

    { organization:, group:, platform:, project:, feature: }
  end

  describe "factory" do
    it "produce una cella valida" do
      expect(build(:feature_platform)).to be_valid
    end
  end

  describe "unicità" do
    it "rifiuta due celle per la stessa funzionalità e piattaforma" do
      cell = create(:feature_platform)
      duplicate = build(:feature_platform, feature: cell.feature, platform: cell.platform,
                                           status: cell.status)
      expect(duplicate).not_to be_valid
    end

    it "permette la stessa piattaforma su funzionalità diverse" do
      cell = create(:feature_platform)
      other = create(:product_feature, category: cell.feature.category,
                                       organization: cell.feature.organization)
      expect(build(:feature_platform, feature: other, platform: cell.platform, status: cell.status)).to be_valid
    end
  end

  describe "coerenza tenant" do
    it "rifiuta una piattaforma di un'altra organizzazione" do
      feature = create(:product_feature)
      cell = build(:feature_platform, feature: feature,
                                      status: create(:feature_status, organization: feature.organization),
                                      platform: create(:platform, organization: create(:organization)))
      expect(cell).not_to be_valid
    end

    it "rifiuta uno stato di un'altra organizzazione" do
      feature = create(:product_feature)
      cell = build(:feature_platform, feature: feature,
                                      platform: create(:platform, organization: feature.organization),
                                      status: create(:feature_status, organization: create(:organization)))
      expect(cell).not_to be_valid
    end
  end

  describe "stato disattivato" do
    it "non si può creare una cella con uno stato disattivato" do
      feature = create(:product_feature)
      status = create(:feature_status, :inactive, organization: feature.organization)
      cell = build(:feature_platform, feature: feature, status: status)
      expect(cell).not_to be_valid
    end

    it "una cella già scritta resta valida se lo stato viene disattivato dopo" do
      cell = create(:feature_platform)
      cell.status.update!(active: false)
      expect(cell.reload).to be_valid
    end
  end

  describe "coerenza della versione indicata" do
    it "accetta una release di un progetto del prodotto che dichiara quella piattaforma" do
      product = build_product
      release = create(:release, project: product[:project])
      cell = build(:feature_platform, feature: product[:feature], platform: product[:platform],
                                      status: create(:feature_status, :available, organization: product[:organization]),
                                      release: release)
      expect(cell).to be_valid
    end

    it "rifiuta una release di un progetto fuori dal prodotto" do
      product = build_product
      outsider = create(:project, organization: product[:organization])
      Connections::ProjectPlatform.create!(project: outsider, platform: product[:platform])
      cell = build(:feature_platform, feature: product[:feature], platform: product[:platform],
                                      status: create(:feature_status, :available, organization: product[:organization]),
                                      release: create(:release, project: outsider))
      expect(cell).not_to be_valid
    end

    it "rifiuta una release di un progetto del prodotto che non gira su quella piattaforma" do
      product = build_product
      other_platform = create(:platform, organization: product[:organization])
      cell = build(:feature_platform, feature: product[:feature], platform: other_platform,
                                      status: create(:feature_status, :available, organization: product[:organization]),
                                      release: create(:release, project: product[:project]))
      expect(cell).not_to be_valid
    end

    it "rifiuta una versione su uno stato non ancora rilasciato" do
      # "In lavorazione, disponibile dalla 2.1.0" non vuol dire niente: la versione è un fatto,
      # non un obiettivo.
      product = build_product
      cell = build(:feature_platform, feature: product[:feature], platform: product[:platform],
                                      status: create(:feature_status, :in_development, organization: product[:organization]),
                                      release: create(:release, project: product[:project]))
      expect(cell).not_to be_valid
    end

    it "accetta una versione su uno stato in dismissione" do
      product = build_product
      cell = build(:feature_platform, feature: product[:feature], platform: product[:platform],
                                      status: create(:feature_status, :deprecated, organization: product[:organization]),
                                      release: create(:release, project: product[:project]))
      expect(cell).to be_valid
    end

    it "una cella senza versione resta valida" do
      product = build_product
      cell = build(:feature_platform, feature: product[:feature], platform: product[:platform],
                                      status: create(:feature_status, :available, organization: product[:organization]))
      expect(cell).to be_valid
    end
  end

  describe "#release_missing?" do
    it "è vero quando lo stato dice rilasciato ma la versione non c'è" do
      feature = create(:product_feature)
      status = create(:feature_status, :available, organization: feature.organization)
      expect(build(:feature_platform, feature: feature, status: status)).to be_release_missing
    end

    it "è falso quando la versione è indicata" do
      product = build_product
      cell = create(:feature_platform, feature: product[:feature], platform: product[:platform],
                                       status: create(:feature_status, :available, organization: product[:organization]),
                                       release: create(:release, project: product[:project]))
      expect(cell).not_to be_release_missing
    end

    it "è falso quando lo stato non è ancora rilasciato" do
      feature = create(:product_feature)
      status = create(:feature_status, :in_development, organization: feature.organization)
      expect(build(:feature_platform, feature: feature, status: status)).not_to be_release_missing
    end
  end

  describe "scope" do
    it ".released seleziona solo le celle disponibili o in dismissione" do
      feature = create(:product_feature)
      org = feature.organization
      released = create(:feature_platform, feature: feature,
                                           status: create(:feature_status, :available, organization: org))
      create(:feature_platform, feature: feature,
                                status: create(:feature_status, :in_development, organization: org))
      expect(described_class.where(feature: feature).released).to contain_exactly(released)
    end
  end
end
