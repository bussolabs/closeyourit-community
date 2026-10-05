# frozen_string_literal: true

require "rails_helper"

# Le celle della matrice sono protette da FK RESTRICT verso piattaforma e stato, e i rispettivi
# lookup usano dependent: :restrict_with_error. È voluto — cancellare una piattaforma non deve
# portarsi via in silenzio dati redazionali — ma va verificato che non blocchi la cancellazione di
# un'organizzazione o di un macro-progetto, dove le celle devono sparire prima dei lookup.
#
# L'organizzazione si ricarica dal database prima di distruggerla, come fa il controller: su un
# oggetto tenuto in memoria dal setup le collezioni sono già popolate via inverse_of e
# restrict_with_error leggerebbe quella cache invece del database.
RSpec.describe Organizations::Organization, "cancellazione con matrice funzionalità", type: :model do
  it "elimina un'organizzazione che ha una matrice compilata" do
    organization = create(:organization)
    group = create(:group, organization: organization)
    platform = create(:platform, organization: organization)
    category = create(:product_category, group: group, organization: organization)
    feature = create(:product_feature, category: category, organization: organization)
    create(:feature_platform, feature: feature, platform: platform,
                              status: create(:feature_status, organization: organization))

    expect { described_class.find(organization.id).destroy! }
      .to change(Connections::FeaturePlatform, :count).by(-1)

    expect(Product::Category.where(id: category.id)).to be_empty
    expect(Types::FeatureStatus.where(organization_id: organization.id)).to be_empty
    expect(Types::Platform.where(id: platform.id)).to be_empty
  end

  it "elimina un macro-progetto che ha una matrice compilata" do
    cell = create(:feature_platform)

    expect { cell.feature.category.group.destroy! }
      .to change(Connections::FeaturePlatform, :count).by(-1)
  end

  it "non cancella una piattaforma che ha caselle compilate" do
    cell = create(:feature_platform)

    expect(Types::Platform.find(cell.platform_id).destroy).to be(false)
    expect(cell.reload).to be_persisted
  end

  it "non cancella uno stato che ha caselle compilate" do
    cell = create(:feature_platform)

    expect(Types::FeatureStatus.find(cell.status_id).destroy).to be(false)
    expect(cell.reload).to be_persisted
  end
end
