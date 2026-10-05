# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Product::Matrices", type: :request do
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

  before { create(:membership, account: owner, organization:, role: :owner) }

  it "senza bearer → 401" do
    get "/cli/v1/product/matrix"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index" do
    it "elenca i prodotti visibili con la paginazione" do
      group

      get "/cli/v1/product/matrix", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |row| row["id"] }).to include(group.id)
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "esclude i prodotti di un'altra org (anti-BOLA)" do
      group
      other = create(:group)

      get "/cli/v1/product/matrix", headers: headers

      expect(response.parsed_body["data"].map { |row| row["id"] }).not_to include(other.id)
    end

    it "per un member elenca SOLO i prodotti assegnati" do
      create(:membership, account: member, organization:, role: :member)
      Authorization::SetAccountPermissions.call(organization:, account: member,
                                                allow_keys: [ "product_features.view" ], actor: owner)
      assigned = create(:group, organization:, name: "Assegnato")
      create(:group_membership, account: member, group: assigned)
      unassigned = group
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      get "/cli/v1/product/matrix", headers: { "Authorization" => "Bearer #{member_secret}" }

      ids = response.parsed_body["data"].map { |row| row["id"] }
      expect(ids).to include(assigned.id)
      expect(ids).not_to include(unassigned.id)
    end

    it "senza product_features.view → 403" do
      create(:membership, account: member, organization:, role: :member)
      Authorization::SetAccountPermissions.call(organization:, account: member, allow_keys: [], actor: owner)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      get "/cli/v1/product/matrix", headers: { "Authorization" => "Bearer #{member_secret}" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  describe "GET show" do
    it "rende prodotto, colonne, categorie con funzionalità e celle" do
      project
      status = create(:feature_status, :available, organization:)
      release = create(:release, project:, version: "2.1.0")
      create(:feature_platform, feature:, platform:, status:, release:)

      get "/cli/v1/product/matrix/#{group.id}", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["product"]).to include("id" => group.id, "name" => "DriverOne")
      expect(data["platforms"].map { |row| row["code"] }).to eq([ "web" ])
      expect(data["categories"].first).to include("name" => "Auth")
      expect(data["categories"].first["features"].map { |row| row["name"] }).to eq([ "2FA" ])

      cell = data["cells"].first
      expect(cell).to include("feature_id" => feature.id, "platform_id" => platform.id,
                              "platform_code" => platform.code)
      expect(cell["status"]).to include("code" => status.code, "category" => "available")
      expect(cell["release"]).to include("version" => "2.1.0", "project_key" => project.key)
      expect(cell["release_missing"]).to be(false)
      expect(data["missing_release_count"]).to eq(0)
    end

    it "conta le celle rilasciate senza versione" do
      project
      status = create(:feature_status, :available, organization:)
      create(:feature_platform, feature:, platform:, status:)

      get "/cli/v1/product/matrix/#{group.id}", headers: headers

      expect(response.parsed_body["data"]["cells"].first["release_missing"]).to be(true)
      expect(response.parsed_body["data"]["missing_release_count"]).to eq(1)
    end

    it "mostra come colonna anche una piattaforma disattivata che ha già celle" do
      retired = create(:platform, organization:, code: "legacy", active: false)
      create(:feature_platform, feature:, platform: retired,
                                status: create(:feature_status, organization:))

      get "/cli/v1/product/matrix/#{group.id}", headers: headers

      expect(response.parsed_body["data"]["platforms"].map { |row| row["code"] }).to include("legacy")
    end

    it "un prodotto di un'altra org → 404 (anti-BOLA)" do
      other = create(:group)

      get "/cli/v1/product/matrix/#{other.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
    end

    # Prosopite gira su ogni request spec: con più celle in pagina, una show senza preload di
    # stato/release/progetto fallisce qui. Il setup sta fuori dallo scan (la validazione tenant di
    # ogni cella creata è una query per-record del setup, non un N+1 di produzione).
    it "regge più celle senza una query per cella" do
      allow_n_plus_one do
        project
        status = create(:feature_status, :available, organization:)
        release = create(:release, project:, version: "2.1.0")
        3.times do |index|
          other_feature = create(:product_feature, category:, organization:, name: "Feature #{index}")
          create(:feature_platform, feature: other_feature, platform:, status:, release:)
        end
      end

      get "/cli/v1/product/matrix/#{group.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["cells"].size).to eq(3)
    end
  end
end
