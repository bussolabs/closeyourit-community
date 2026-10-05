# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::OrganizationSwitches", type: :request do
  let(:account) { create(:account) }
  let(:org_a) { create(:organization, name: "Org A") }
  let(:org_b) { create(:organization, name: "Org B") }

  before do
    create(:membership, account: account, organization: org_a, role: :owner)
    create(:membership, account: account, organization: org_b, role: :member)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "passa a un'organizzazione di cui è membro" do
    post member_organization_switches_path, params: { organization_id: org_b.id }
    expect(response).to redirect_to(root_path)
    expect(flash[:notice]).to be_present
  end

  it "lands on the local path given as return_to" do
    post member_organization_switches_path, params: { organization_id: org_b.id, return_to: "/member/projects" }
    expect(response).to redirect_to("/member/projects")
  end

  %w[https://evil.example //evil.example].each do |external|
    it "ignores an external return_to (#{external}) and lands on root" do
      post member_organization_switches_path, params: { organization_id: org_b.id, return_to: external }
      expect(response).to redirect_to(root_path)
    end
  end

  it "BOLA: rifiuta un'org di cui NON è membro" do
    other = create(:organization)
    post member_organization_switches_path, params: { organization_id: other.id }
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to be_present
  end

  context "account god (cross-tenant nativo)" do
    let(:god) { create(:account, god: true) }

    it "passa a un'org di cui NON è membro" do
      target = create(:organization, name: "Foreign Org")
      post login_path, params: { email: god.email, password: "Secret123!" }
      post member_organization_switches_path, params: { organization_id: target.id }
      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to be_present
    end
  end
end
