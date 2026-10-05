# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Product::Features", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:group) { create(:group, organization: org, name: "DriverOne") }
  let(:category) { create(:product_category, group: group, organization: org, name: "Auth") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET new" do
    it "senza product_features.manage → redirect" do
      Authorization::SetAccountPermissions.call(organization: org, account: member,
                                                allow_keys: [ "product_features.view" ], actor: owner)
      sign_in(member)

      get new_member_product_feature_path(matrix_id: group.id)

      expect(response).to redirect_to(root_path)
    end

    it "preseleziona la categoria di partenza" do
      category
      sign_in(owner)

      get new_member_product_feature_path(category_id: category.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("product-feature-form")
    end
  end

  describe "POST create" do
    it "crea la funzionalità nella categoria scelta" do
      sign_in(owner)

      expect do
        post member_product_features_path(matrix_id: group.id),
             params: { name: "2FA", category_id: category.id }
      end.to change(Product::Feature, :count).by(1)

      expect(Product::Feature.last.category).to eq(category)
      expect(response).to redirect_to(member_product_matrix_path(group))
    end

    it "collega la pagina della base di conoscenza" do
      page = create(:knowledge_page, organization: org)
      sign_in(owner)

      post member_product_features_path(matrix_id: group.id),
           params: { name: "2FA", category_id: category.id, knowledge_page_id: page.id }

      expect(Product::Feature.last.knowledge_page).to eq(page)
    end

    it "rifiuta una pagina non visibile all'autore" do
      foreign_page = create(:knowledge_page, organization: create(:organization))
      sign_in(owner)

      post member_product_features_path(matrix_id: group.id),
           params: { name: "2FA", category_id: category.id, knowledge_page_id: foreign_page.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Product::Feature.count).to eq(0)
    end

    it "rifiuta una categoria di un altro prodotto" do
      foreign_category = create(:product_category)
      sign_in(owner)

      post member_product_features_path(matrix_id: group.id),
           params: { name: "2FA", category_id: foreign_category.id }

      expect(response).to redirect_to(member_product_matrix_path(group))
      expect(Product::Feature.count).to eq(0)
    end
  end

  describe "PATCH update" do
    it "rinomina la funzionalità" do
      feature = create(:product_feature, category: category, organization: org, name: "2FA")
      sign_in(owner)

      patch member_product_feature_path(feature), params: { name: "Due fattori", category_id: category.id }

      expect(feature.reload.name).to eq("Due fattori")
    end

    it "nome duplicato nella categoria → 422 e riapre il form" do
      create(:product_feature, category: category, organization: org, name: "2FA")
      feature = create(:product_feature, category: category, organization: org, name: "Apple login")
      sign_in(owner)

      patch member_product_feature_path(feature), params: { name: "2FA", category_id: category.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(feature.reload.name).to eq("Apple login")
    end

    it "404 su una funzionalità di un altro tenant" do
      foreign = create(:product_feature)
      sign_in(owner)

      patch member_product_feature_path(foreign), params: { name: "X" }

      expect(response).to have_http_status(:not_found)
    end

    it "rifiuta una categoria di un altro prodotto invece di ignorarla" do
      feature = create(:product_feature, category: category, organization: org, name: "2FA")
      foreign_category = create(:product_category)
      sign_in(owner)

      patch member_product_feature_path(feature),
            params: { name: "Rinominata", category_id: foreign_category.id }

      expect(flash[:alert]).to eq(I18n.t("member.product.features.errors.category_not_found"))
      expect(feature.reload.name).to eq("2FA")
      expect(feature.category).to eq(category)
    end

    it "senza il campo categoria mantiene quella attuale (update parziale)" do
      feature = create(:product_feature, category: category, organization: org, name: "2FA")
      sign_in(owner)

      patch member_product_feature_path(feature), params: { name: "Due fattori" }

      expect(feature.reload.name).to eq("Due fattori")
      expect(feature.category).to eq(category)
    end

    it "tiene in elenco la pagina KB già collegata anche oltre il limite" do
      # Senza, la tendina rimanderebbe "nessuna" e il salvataggio scollegherebbe la pagina.
      page = create(:knowledge_page, organization: org, title: "zzz ultima in ordine")
      feature = create(:product_feature, category: category, organization: org, knowledge_page: page)
      stub_const("Member::Product::FeaturesController::PAGES_LIMIT", 1)
      create(:knowledge_page, organization: org, title: "aaa prima in ordine")
      sign_in(owner)

      get edit_member_product_feature_path(feature)

      expect(response.body).to include(page.title)
    end
  end

  describe "DELETE destroy" do
    it "elimina la funzionalità e le sue caselle" do
      feature = create(:product_feature, category: category, organization: org)
      create(:feature_platform, feature: feature,
                                platform: create(:platform, organization: org),
                                status: create(:feature_status, organization: org))
      sign_in(owner)

      expect { delete member_product_feature_path(feature) }
        .to change(Product::Feature, :count).by(-1)
        .and change(Connections::FeaturePlatform, :count).by(-1)
    end
  end
end
