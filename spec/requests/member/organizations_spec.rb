# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Organizations", type: :request do
  let(:org) { create(:organization, name: "Acme", slug: "acme") }
  let(:owner) { create(:account) }
  let!(:owner_m) { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET edit" do
    it "owner → 200" do
      sign_in(owner)
      get edit_member_organization_path
      expect(response).to have_http_status(:ok)
    end

    # T3 — the long form is split in three named parts, in the order the fields already had.
    it "splits the form into identity, retention and people" do
      sign_in(owner)
      get edit_member_organization_path

      sections = Capybara.string(response.body).all("[data-test^='organization-section-']").map { |node| node["data-test"] }
      expect(sections).to eq(%w[organization-section-identity organization-section-retention organization-section-people])
    end

    # O7 — the CTO field was written in Italian inside the page: it reads from the translation files.
    it "shows the CTO field in the page language" do
      sign_in(owner)
      get edit_member_organization_path(locale: :en)

      field = Capybara.string(response.body).find("[data-test='organization-cto']")
      expect(field).to have_text(I18n.t("member.organization.cto_label", locale: :en))
      expect(field).to have_text(I18n.t("member.organization.cto_hint", locale: :en))
      expect(field).to have_no_text("CTO organizzativo")
    end

    it "admin (non owner) → redirect home" do
      admin = create(:account)
      create(:membership, account: admin, organization: org, role: :admin)
      sign_in(admin)
      get edit_member_organization_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "PATCH update" do
    it "owner rinomina l'organizzazione" do
      sign_in(owner)
      patch member_organization_path, params: { confirm: "1", name: "Acme Renamed", slug: "acme-renamed" }
      expect(response).to redirect_to(edit_member_organization_path)
      expect(org.reload.name).to eq("Acme Renamed")
    end

    it "nome vuoto → 422 render edit" do
      sign_in(owner)
      patch member_organization_path, params: { name: "", slug: "acme" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(org.reload.name).to eq("Acme")
    end

    it "owner imposta il default_projects_view dell'organizzazione" do
      sign_in(owner)
      patch member_organization_path, params: { confirm: "1", name: "Acme", slug: "acme", default_projects_view: "table" }
      expect(response).to redirect_to(edit_member_organization_path)
      expect(org.reload.default_projects_view).to eq("table")
    end

    it "admin (non owner) non può modificare il default org" do
      admin = create(:account)
      create(:membership, account: admin, organization: org, role: :admin)
      sign_in(admin)
      patch member_organization_path, params: { name: "Acme", slug: "acme", default_projects_view: "table" }
      expect(response).to redirect_to(root_path)
      expect(org.reload.default_projects_view).to be_nil
    end

    it "owner imposta la retention log di default dell'org" do
      sign_in(owner)
      patch member_organization_path, params: { confirm: "1", name: "Acme", slug: "acme", logs_retention_days: 30 }
      expect(response).to redirect_to(edit_member_organization_path)
      expect(org.reload.logs_retention_days).to eq(30)
    end

    it "una retention blank eredita (azzera l'override org)" do
      org.update!(logs_retention_days: 30)
      sign_in(owner)
      patch member_organization_path, params: { confirm: "1", name: "Acme", slug: "acme", logs_retention_days: "" }
      expect(org.reload.logs_retention_days).to be_nil
    end

    it "rifiuta una retention fuori da 1..365 → 422" do
      sign_in(owner)
      patch member_organization_path, params: { name: "Acme", slug: "acme", logs_retention_days: 999 }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "owner imposta la retention errori/performance/server/uptime di default dell'org (CYRA-159)" do
      sign_in(owner)
      patch member_organization_path, params: { confirm: "1", name: "Acme", slug: "acme", errors_retention_days: 90,
                                                 performance_retention_days: 60, servers_retention_days: 15,
                                                 uptime_retention_days: 365 }
      expect(response).to redirect_to(edit_member_organization_path)
      org.reload
      expect(org.errors_retention_days).to eq(90)
      expect(org.performance_retention_days).to eq(60)
      expect(org.servers_retention_days).to eq(15)
      expect(org.uptime_retention_days).to eq(365)
    end

    it "rifiuta una retention server fuori da 1..365 → 422" do
      sign_in(owner)
      patch member_organization_path, params: { name: "Acme", slug: "acme", servers_retention_days: 999 }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "owner imposta l'assegnatario di default dei ticket dell'org" do
      assignee = create(:account)
      create(:membership, account: assignee, organization: org, role: :member)
      sign_in(owner)
      patch member_organization_path, params: { confirm: "1", name: "Acme", slug: "acme", default_assignee_id: assignee.id }
      expect(response).to redirect_to(edit_member_organization_path)
      expect(org.reload.default_assignee).to eq(assignee)
    end

    it "rifiuta un default_assignee non membro dell'org → 422" do
      outsider = create(:account)
      sign_in(owner)
      patch member_organization_path, params: { name: "Acme", slug: "acme", default_assignee_id: outsider.id }
      expect(response).to have_http_status(:unprocessable_content)
      expect(org.reload.default_assignee).to be_nil
    end
  end
end
