# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Product::Categories", type: :request do
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account: owner, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:group) { create(:group, organization:, name: "DriverOne") }
  let(:category) { create(:product_category, group:, organization:, name: "Auth") }

  before { create(:membership, account: owner, organization:, role: :owner) }

  it "senza bearer → 401" do
    get "/cli/v1/product/matrix/#{group.id}/categories"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index" do
    it "elenca le categorie del prodotto, ordinate" do
      second = create(:product_category, group:, organization:, name: "Notifiche", position: 1)
      category

      get "/cli/v1/product/matrix/#{group.id}/categories", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |row| row["name"] }).to eq([ "Auth", "Notifiche" ])
      expect(response.parsed_body["data"].last["id"]).to eq(second.id)
      expect(response.parsed_body["meta"]).to include("page", "total")
    end

    it "non mostra le categorie di un altro prodotto" do
      category
      other_group = create(:group, organization:)
      other = create(:product_category, group: other_group, organization:, name: "Altrove")

      get "/cli/v1/product/matrix/#{group.id}/categories", headers: headers

      expect(response.parsed_body["data"].map { |row| row["id"] }).not_to include(other.id)
    end
  end

  describe "POST create" do
    it "crea la categoria → 201" do
      expect do
        post "/cli/v1/product/matrix/#{group.id}/categories", headers: headers,
                                                              params: { name: "Auth", position: 2 }
      end.to change(Product::Category, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("name" => "Auth", "position" => 2)
      expect(Product::Category.last.organization_id).to eq(organization.id)
    end

    it "nome duplicato nello stesso prodotto → 422" do
      category

      post "/cli/v1/product/matrix/#{group.id}/categories", headers: headers, params: { name: "Auth" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PRODUCT-001")
    end

    it "senza product_features.manage → 403" do
      create(:membership, account: member, organization:, role: :member)
      create(:group_membership, account: member, group:)
      Authorization::SetAccountPermissions.call(organization:, account: member,
                                                allow_keys: [ "product_features.view" ], actor: owner)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      post "/cli/v1/product/matrix/#{group.id}/categories",
           headers: { "Authorization" => "Bearer #{member_secret}" }, params: { name: "Auth" }

      expect(response).to have_http_status(:forbidden)
    end

    it "su un prodotto di un'altra org → 404 (anti-BOLA, prima del gate)" do
      other = create(:group)

      post "/cli/v1/product/matrix/#{other.id}/categories", headers: headers, params: { name: "Auth" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH update" do
    it "rinomina per id" do
      patch "/cli/v1/product/matrix/#{group.id}/categories/#{category.id}",
            headers: headers, params: { name: "Accesso" }

      expect(response).to have_http_status(:ok)
      expect(category.reload.name).to eq("Accesso")
    end

    it "risolve la categoria per nome (unico dentro il prodotto)" do
      category

      patch "/cli/v1/product/matrix/#{group.id}/categories/Auth", headers: headers, params: { position: 3 }

      expect(response).to have_http_status(:ok)
      expect(category.reload.position).to eq(3)
    end

    it "una categoria di un altro prodotto → 404 (anti-BOLA)" do
      other = create(:product_category, group: create(:group, organization:), organization:)

      patch "/cli/v1/product/matrix/#{group.id}/categories/#{other.id}", headers: headers, params: { name: "X" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy" do
    it "elimina una categoria vuota → 204" do
      category

      expect do
        delete "/cli/v1/product/matrix/#{group.id}/categories/#{category.id}", headers: headers
      end.to change(Product::Category, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "rifiuta una categoria con funzionalità → 422" do
      create(:product_feature, category:, organization:)

      delete "/cli/v1/product/matrix/#{group.id}/categories/#{category.id}", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PRODUCT-004")
      expect(category.reload).to be_persisted
    end
  end
end
