# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Product::Features", type: :request do
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account: owner, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:group) { create(:group, organization:, name: "DriverOne") }
  let(:category) { create(:product_category, group:, organization:, name: "Auth") }
  let(:feature) { create(:product_feature, category:, organization:, name: "2FA") }

  before { create(:membership, account: owner, organization:, role: :owner) }

  it "senza bearer → 401" do
    get "/cli/v1/product/matrix/#{group.id}/features"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index" do
    it "elenca le funzionalità del prodotto con la categoria" do
      feature

      get "/cli/v1/product/matrix/#{group.id}/features", headers: headers

      expect(response).to have_http_status(:ok)
      row = response.parsed_body["data"].first
      expect(row).to include("id" => feature.id, "name" => "2FA", "category_id" => category.id)
      expect(row["category_name"]).to eq("Auth")
      expect(response.parsed_body["meta"]).to include("page", "total")
    end

    it "filtra per categoria (id o nome)" do
      feature
      other_category = create(:product_category, group:, organization:, name: "Notifiche")
      other = create(:product_feature, category: other_category, organization:, name: "Push")

      get "/cli/v1/product/matrix/#{group.id}/features?category=Notifiche", headers: headers

      ids = response.parsed_body["data"].map { |row| row["id"] }
      expect(ids).to eq([ other.id ])
      expect(ids).not_to include(feature.id)
    end

    it "non mostra le funzionalità di un altro prodotto" do
      feature
      other = create(:product_feature, category: create(:product_category, group: create(:group, organization:),
                                                                          organization:), organization:)

      get "/cli/v1/product/matrix/#{group.id}/features", headers: headers

      expect(response.parsed_body["data"].map { |row| row["id"] }).not_to include(other.id)
    end
  end

  describe "GET show" do
    it "rende la funzionalità con le sue celle" do
      platform = create(:platform, organization:, code: "web")
      status = create(:feature_status, :available, organization:)
      create(:feature_platform, feature:, platform:, status:)

      get "/cli/v1/product/matrix/#{group.id}/features/#{feature.id}", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data).to include("id" => feature.id, "name" => "2FA")
      expect(data["cells"].first).to include("platform_id" => platform.id, "platform_code" => platform.code)
      expect(data["cells"].first["status"]).to include("code" => status.code)
    end

    it "risolve la funzionalità per \"Categoria/Nome\"" do
      feature

      get "/cli/v1/product/matrix/#{group.id}/features/#{CGI.escape('Auth/2FA')}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["id"]).to eq(feature.id)
    end

    it "un nome inesistente → 404" do
      get "/cli/v1/product/matrix/#{group.id}/features/#{CGI.escape('Auth/Manca')}", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "una funzionalità di un altro prodotto → 404 (anti-BOLA)" do
      other = create(:product_feature, category: create(:product_category, group: create(:group, organization:),
                                                                          organization:), organization:)

      get "/cli/v1/product/matrix/#{group.id}/features/#{other.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    it "crea la funzionalità nella categoria indicata per nome → 201" do
      category

      expect do
        post "/cli/v1/product/matrix/#{group.id}/features", headers: headers,
                                                            params: { category: "Auth", name: "Apple login",
                                                                      description: "Accesso con Apple" }
      end.to change(Product::Feature, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("name" => "Apple login", "category_id" => category.id)
    end

    it "collega una pagina della base di conoscenza" do
      page = create(:knowledge_page, project: create(:project, organization:, group:))

      post "/cli/v1/product/matrix/#{group.id}/features", headers: headers,
                                                          params: { category: category.name, name: "Apple login",
                                                                    knowledge_page_id: page.id }

      expect(response).to have_http_status(:created)
      expect(Product::Feature.last.knowledge_page_id).to eq(page.id)
    end

    it "senza categoria → 404" do
      post "/cli/v1/product/matrix/#{group.id}/features", headers: headers, params: { name: "Orfana" }

      expect(response).to have_http_status(:not_found)
    end

    it "categoria di un altro prodotto → 404 (anti-BOLA)" do
      other = create(:product_category, group: create(:group, organization:), organization:)

      post "/cli/v1/product/matrix/#{group.id}/features", headers: headers,
                                                          params: { category: other.id, name: "Intrusa" }

      expect(response).to have_http_status(:not_found)
    end

    it "nome duplicato nella stessa categoria → 422" do
      feature

      post "/cli/v1/product/matrix/#{group.id}/features", headers: headers,
                                                          params: { category: "Auth", name: "2FA" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-PRODUCT-002")
    end

    it "senza product_features.manage → 403" do
      create(:membership, account: member, organization:, role: :member)
      create(:group_membership, account: member, group:)
      Authorization::SetAccountPermissions.call(organization:, account: member,
                                                allow_keys: [ "product_features.view" ], actor: owner)
      member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
      category

      post "/cli/v1/product/matrix/#{group.id}/features",
           headers: { "Authorization" => "Bearer #{member_secret}" }, params: { category: "Auth", name: "X" }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH update" do
    it "aggiorna solo i campi passati" do
      feature.update!(description: "Descrizione originale")

      patch "/cli/v1/product/matrix/#{group.id}/features/#{feature.id}", headers: headers,
                                                                         params: { name: "Due fattori" }

      expect(response).to have_http_status(:ok)
      expect(feature.reload.name).to eq("Due fattori")
      expect(feature.description).to eq("Descrizione originale")
    end

    it "sposta la funzionalità in un'altra categoria dello stesso prodotto" do
      destination = create(:product_category, group:, organization:, name: "Notifiche")

      patch "/cli/v1/product/matrix/#{group.id}/features/#{feature.id}", headers: headers,
                                                                         params: { category: "Notifiche" }

      expect(response).to have_http_status(:ok)
      expect(feature.reload.category_id).to eq(destination.id)
    end

    it "una categoria inviata ma non riconosciuta → 404, e non sposta" do
      original = feature.category_id

      patch "/cli/v1/product/matrix/#{group.id}/features/#{feature.id}", headers: headers,
                                                                         params: { category: "Inesistente" }

      expect(response).to have_http_status(:not_found)
      expect(feature.reload.category_id).to eq(original)
    end
  end

  describe "DELETE destroy" do
    it "elimina la funzionalità e le sue celle → 204" do
      platform = create(:platform, organization:, code: "web")
      create(:feature_platform, feature:, platform:, status: create(:feature_status, organization:))

      expect do
        delete "/cli/v1/product/matrix/#{group.id}/features/#{feature.id}", headers: headers
      end.to change(Product::Feature, :count).by(-1)
                                             .and change(Connections::FeaturePlatform, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end
  end
end
