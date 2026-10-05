# frozen_string_literal: true

require "rails_helper"

# The Vault landing (CYRA-135, CYRA-930): the header counts the secrets of no project, the table the
# project ones.
RSpec.describe "Member::Vault overview", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET overview" do
    # CYRA-930 — project secrets are counted row by row; personal and organization ones in the header.
    it "counts the project secrets in the table and the others in the header" do
      sign_in(owner)
      create(:secret_variable, project: project, organization: org)
      Secrets::Shared::Variable.create!(organization: org, name: "ORG_ONE")

      get member_vault_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='vault-row-#{project.id}'] [data-test='vault-cell-variables'] [data-test='vault-cell-value']").text.strip).to eq("1")
      expect(doc.at_css("[data-test='vault-count-organization']").text).to match(/1/)
      expect(doc.at_css("[data-test='vault-count-personal']").text).to match(/0/)
    end

    it "un membro senza secrets_audit.view non vede azione/nome dei secret nel feed (no information disclosure)" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      create(:project_membership, account: member, project: project)
      sign_in(member)
      create(:secret_event, project: project, organization: org, action: "set", name: "TOPSECRET")

      get member_vault_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("TOPSECRET")
      expect(response.body).not_to include('data-test="vault-overview-activity"')
    end
  end
end
