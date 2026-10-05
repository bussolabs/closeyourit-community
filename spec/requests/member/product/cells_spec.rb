# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Product::Features::Cells", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:group) { create(:group, organization: org, name: "DriverOne") }
  let(:platform) { create(:platform, organization: org, label: "Web") }
  let(:project) do
    create(:project, organization: org, group: group).tap do |project|
      Connections::ProjectPlatform.create!(project: project, platform: platform)
    end
  end
  let(:category) { create(:product_category, group: group, organization: org) }
  let(:feature) { create(:product_feature, category: category, organization: org, name: "2FA") }
  let(:status) { create(:feature_status, :available, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET edit" do
    it "senza product_features.manage → redirect (la edit è già scrittura)" do
      Authorization::SetAccountPermissions.call(organization: org, account: member,
                                                allow_keys: [ "product_features.view" ], actor: owner)
      project
      sign_in(member)

      get edit_member_product_feature_cell_path(feature, platform)

      expect(response).to redirect_to(root_path)
    end

    it "mostra gli stati e le versioni indicabili" do
      release = create(:release, project: project, version: "2.1.0")
      status
      sign_in(owner)

      get edit_member_product_feature_cell_path(feature, platform)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(status.label, "2.1.0", ERB::Util.html_escape(release.project.name))
    end

    it "avvisa quando non c'è nessuna versione registrata" do
      project
      status
      sign_in(owner)

      get edit_member_product_feature_cell_path(feature, platform)

      expect(response.body).to include("product-cell-no-releases")
    end

    it "404 su una piattaforma che non è una colonna della matrice" do
      outsider = create(:platform, organization: org)
      project
      sign_in(owner)

      get edit_member_product_feature_cell_path(feature, outsider)

      expect(response).to have_http_status(:not_found)
    end

    it "404 su una funzionalità di un altro tenant" do
      foreign = create(:product_feature)
      sign_in(owner)

      get edit_member_product_feature_cell_path(foreign, platform)

      expect(response).to have_http_status(:not_found)
    end

    it "su una piattaforma disattivata si corregge una casella esistente" do
      # La colonna resta visibile finché ha caselle: quelle si devono poter sistemare.
      create(:feature_platform, feature: feature, platform: platform, status: status)
      platform.update!(active: false)
      sign_in(owner)

      get edit_member_product_feature_cell_path(feature, platform)

      expect(response).to have_http_status(:ok)
    end

    it "su una piattaforma disattivata non si apre una casella ancora vuota" do
      # La colonna c'è per via di un'altra funzionalità, ma la piattaforma è dismessa: niente celle nuove.
      other = create(:product_feature, category: category, organization: org, name: "Altra")
      create(:feature_platform, feature: other, platform: platform, status: status)
      platform.update!(active: false)
      sign_in(owner)

      get edit_member_product_feature_cell_path(feature, platform)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH update" do
    it "salva stato e versione" do
      release = create(:release, project: project, version: "2.1.0")
      sign_in(owner)

      patch member_product_feature_cell_path(feature, platform),
            params: { status_id: status.id, release_id: release.id }

      cell = Connections::FeaturePlatform.find_by(feature: feature, platform: platform)
      expect(cell.status).to eq(status)
      expect(cell.release).to eq(release)
      expect(response).to redirect_to(member_product_matrix_path(group))
    end

    it "salva senza versione" do
      project
      sign_in(owner)

      patch member_product_feature_cell_path(feature, platform), params: { status_id: status.id }

      expect(Connections::FeaturePlatform.find_by(feature: feature, platform: platform).release).to be_nil
    end

    it "rifiuta una versione non ammissibile per prodotto e piattaforma" do
      outsider = create(:project, organization: org)
      Connections::ProjectPlatform.create!(project: outsider, platform: platform)
      foreign_release = create(:release, project: outsider)
      project
      sign_in(owner)

      patch member_product_feature_cell_path(feature, platform),
            params: { status_id: status.id, release_id: foreign_release.id }

      expect(Connections::FeaturePlatform.count).to eq(0)
      expect(flash[:alert]).to eq(I18n.t("member.product.cells.errors.release_not_found"))
    end
  end

  describe "DELETE destroy" do
    it "azzera la cella" do
      project
      create(:feature_platform, feature: feature, platform: platform, status: status)
      sign_in(owner)

      expect do
        delete member_product_feature_cell_path(feature, platform)
      end.to change(Connections::FeaturePlatform, :count).by(-1)
    end
  end

  describe "GET new / POST create — prima colonna" do
    it "propone le piattaforme su cui la funzionalità non è ancora segnata" do
      ios = create(:platform, organization: org, label: "iOS")
      status
      sign_in(owner)

      get new_member_product_feature_cell_path(feature)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ios.label)
    end

    it "segna la funzionalità su una piattaforma senza progetti e la colonna compare in matrice" do
      # Il requisito: tracciare iOS prima che esista il progetto iOS.
      ios = create(:platform, organization: org, label: "iOS")
      sign_in(owner)

      post member_product_feature_cells_path(feature), params: { platform_id: ios.id, status_id: status.id }

      expect(Connections::FeaturePlatform.find_by(feature: feature, platform: ios)).to be_present
      get member_product_matrix_path(group)
      expect(response.body).to include("iOS")
    end

    it "404 su una piattaforma di un'altra organizzazione" do
      foreign = create(:platform, organization: create(:organization))
      sign_in(owner)

      post member_product_feature_cells_path(feature), params: { platform_id: foreign.id, status_id: status.id }

      expect(response).to have_http_status(:not_found)
    end

    it "404 su una piattaforma disattivata" do
      inactive = create(:platform, organization: org, active: false)
      sign_in(owner)

      post member_product_feature_cells_path(feature), params: { platform_id: inactive.id, status_id: status.id }

      expect(response).to have_http_status(:not_found)
    end
  end
end
