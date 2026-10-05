# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Product::Categories", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:group) { create(:group, organization: org, name: "DriverOne") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "gate di gestione" do
    it "senza product_features.manage non si accede al form" do
      Authorization::SetAccountPermissions.call(organization: org, account: member,
                                                allow_keys: [ "product_features.view" ], actor: owner)
      sign_in(member)

      get new_member_product_category_path(matrix_id: group.id)

      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST create" do
    it "crea la categoria e torna alla matrice" do
      sign_in(owner)

      expect do
        post member_product_categories_path(matrix_id: group.id), params: { name: "Auth" }
      end.to change(Product::Category, :count).by(1)

      expect(response).to redirect_to(member_product_matrix_path(group))
      expect(Product::Category.last.group).to eq(group)
    end

    it "404 su un prodotto non visibile (anti-BOLA)" do
      Authorization::SetAccountPermissions.call(organization: org, account: member,
                                                allow_keys: [ "product_features.manage" ], actor: owner)
      sign_in(member)

      post member_product_categories_path(matrix_id: group.id), params: { name: "Auth" }

      expect(response).to have_http_status(:not_found)
    end

    it "nome duplicato → 422 e riapre il form" do
      create(:product_category, group: group, organization: org, name: "Auth")
      sign_in(owner)

      post member_product_categories_path(matrix_id: group.id), params: { name: "Auth" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("product-category-form")
    end
  end

  describe "PATCH update" do
    it "rinomina la categoria" do
      category = create(:product_category, group: group, organization: org, name: "Auth")
      sign_in(owner)

      patch member_product_category_path(category), params: { name: "Accesso" }

      expect(category.reload.name).to eq("Accesso")
      expect(response).to redirect_to(member_product_matrix_path(group))
    end

    it "nome duplicato → 422 e riapre il form di modifica" do
      create(:product_category, group: group, organization: org, name: "Auth")
      category = create(:product_category, group: group, organization: org, name: "Notifiche")
      sign_in(owner)

      patch member_product_category_path(category), params: { name: "Auth" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(category.reload.name).to eq("Notifiche")
    end

    it "404 su una categoria di un'altra organizzazione" do
      foreign = create(:product_category)
      sign_in(owner)

      patch member_product_category_path(foreign), params: { name: "X" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy" do
    it "elimina una categoria vuota" do
      category = create(:product_category, group: group, organization: org)
      sign_in(owner)

      expect do
        delete member_product_category_path(category)
      end.to change(Product::Category, :count).by(-1)
    end

    it "rifiuta l'eliminazione di una categoria che contiene funzionalità" do
      category = create(:product_category, group: group, organization: org)
      create(:product_feature, category: category, organization: org)
      sign_in(owner)

      expect { delete member_product_category_path(category) }.not_to change(Product::Category, :count)
      expect(flash[:alert]).to eq(I18n.t("member.product.categories.errors.not_empty"))
    end
  end
end
