# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Product::Features::Cells", type: :request do
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account: owner, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:group) { create(:group, organization:, name: "DriverOne") }
  let(:platform) { create(:platform, organization:, code: "web", label: "Web") }
  let(:project) do
    create(:project, organization:, group:).tap do |project|
      Connections::ProjectPlatform.create!(project:, platform:)
    end
  end
  let(:category) { create(:product_category, group:, organization:, name: "Auth") }
  let(:feature) { create(:product_feature, category:, organization:, name: "2FA") }
  let(:available) { create(:feature_status, :available, organization:) }
  let(:planned) { create(:feature_status, organization:, code: "planned") }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def cell_path(feature_ref = feature.id, platform_ref = platform.code)
    "/cli/v1/product/matrix/#{group.id}/features/#{feature_ref}/cells/#{platform_ref}"
  end

  it "senza bearer → 401" do
    put cell_path
    expect(response).to have_http_status(:unauthorized)
  end

  describe "PUT update (upsert)" do
    it "scrive la cella indicando lo stato per code → 200" do
      project
      available

      expect do
        put cell_path, headers: headers, params: { status: "available" }
      end.to change(Connections::FeaturePlatform, :count).by(1)

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data).to include("feature_id" => feature.id, "platform_id" => platform.id,
                              "platform_code" => platform.code)
      expect(data["status"]).to include("code" => available.code)
      expect(data["release"]).to be_nil
      expect(data["release_missing"]).to be(true)
    end

    it "indica la versione per numero (release del prodotto su quella piattaforma)" do
      release = create(:release, project:, version: "2.1.0")
      available

      put cell_path, headers: headers, params: { status: "available", release: "2.1.0" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["release"]).to include("version" => "2.1.0")
      expect(Connections::FeaturePlatform.last.release_id).to eq(release.id)
      expect(response.parsed_body["data"]["release_missing"]).to be(false)
    end

    it "aggiorna una cella già scritta invece di crearne una seconda" do
      create(:feature_platform, feature:, platform:, status: planned)
      available

      expect do
        put cell_path, headers: headers, params: { status: "available" }
      end.not_to change(Connections::FeaturePlatform, :count)

      expect(Connections::FeaturePlatform.last.status_id).to eq(available.id)
    end

    it "riportando la cella a uno stato non rilasciato stacca la versione" do
      release = create(:release, project:, version: "2.1.0")
      create(:feature_platform, feature:, platform:, status: available, release:)
      planned

      put cell_path, headers: headers, params: { status: "planned" }

      expect(response).to have_http_status(:ok)
      expect(Connections::FeaturePlatform.last.release_id).to be_nil
      expect(response.parsed_body["data"]["release"]).to be_nil
    end

    it "risolve la funzionalità per \"Categoria/Nome\" e la piattaforma per id" do
      project
      feature
      available

      put cell_path(CGI.escape("Auth/2FA"), platform.id), headers: headers, params: { status: "available" }

      expect(response).to have_http_status(:ok)
      expect(Connections::FeaturePlatform.last.feature_id).to eq(feature.id)
    end

    it "uno stato disattivato → 404" do
      retired = create(:feature_status, :inactive, organization:, code: "retired")
      project

      put cell_path, headers: headers, params: { status: retired.code }

      expect(response).to have_http_status(:not_found)
      expect(Connections::FeaturePlatform.count).to eq(0)
    end

    it "uno stato di un'altra org → 404" do
      other = create(:feature_status, :available, code: "available")
      project

      put cell_path, headers: headers, params: { status: other.id }

      expect(response).to have_http_status(:not_found)
    end

    it "una versione che non è del prodotto su quella piattaforma → 404 R404-PRODUCT-001" do
      project
      foreign = create(:release, project: create(:project, organization:), version: "9.9.9")
      available

      put cell_path, headers: headers, params: { status: "available", release: foreign.version }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-PRODUCT-001")
      expect(Connections::FeaturePlatform.count).to eq(0)
    end

    it "su una piattaforma attiva senza progetti apre una colonna nuova" do
      fresh = create(:platform, organization:, code: "ios")
      available

      put cell_path(feature.id, "ios"), headers: headers, params: { status: "available" }

      expect(response).to have_http_status(:ok)
      expect(Connections::FeaturePlatform.last.platform_id).to eq(fresh.id)
    end

    it "su una piattaforma disattivata SENZA cella → 404" do
      create(:platform, organization:, code: "legacy", active: false)
      available

      put cell_path(feature.id, "legacy"), headers: headers, params: { status: "available" }

      expect(response).to have_http_status(:not_found)
    end

    it "su una piattaforma disattivata CON cella la correzione resta possibile" do
      retired_platform = create(:platform, organization:, code: "legacy", active: false)
      create(:feature_platform, feature:, platform: retired_platform, status: planned)
      available

      put cell_path(feature.id, "legacy"), headers: headers, params: { status: "available" }

      expect(response).to have_http_status(:ok)
      expect(Connections::FeaturePlatform.last.status_id).to eq(available.id)
    end

    it "una piattaforma di un'altra org → 404 (anti-BOLA)" do
      other = create(:platform, code: "windows")
      available

      put cell_path(feature.id, other.id), headers: headers, params: { status: "available" }

      expect(response).to have_http_status(:not_found)
    end

    it "senza product_features.manage → 403" do
      create(:membership, account: member, organization:, role: :member)
      create(:group_membership, account: member, group:)
      Authorization::SetAccountPermissions.call(organization:, account: member,
                                                allow_keys: [ "product_features.view" ], actor: owner)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
      project
      available

      put cell_path, headers: { "Authorization" => "Bearer #{member_secret}" }, params: { status: "available" }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE destroy" do
    it "azzera la cella → 204" do
      create(:feature_platform, feature:, platform:, status: available)

      expect do
        delete cell_path, headers: headers
      end.to change(Connections::FeaturePlatform, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "azzerare una cella già vuota è idempotente → 204" do
      project

      delete cell_path, headers: headers

      expect(response).to have_http_status(:no_content)
    end
  end
end
