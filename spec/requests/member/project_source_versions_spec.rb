# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectSourceVersions", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:source) { create(:project_source, project:, tool_code: "closeyourit-ruby", version: "0.4.0") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    # Scoping Fase E: il member vede il progetto solo se assegnato.
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "non autenticato → redirect login" do
      get member_project_source_versions_path(project, source)
      expect(response).to redirect_to(login_path)
    end

    it "owner → 200 con la cronologia versioni della fonte" do
      create(:project_source_version, source:, version: "0.3.0", first_seen_at: 10.days.ago, last_seen_at: 5.days.ago)
      create(:project_source_version, source:, version: "0.4.0", first_seen_at: 5.days.ago, last_seen_at: 1.hour.ago)

      sign_in(owner)
      get member_project_source_versions_path(project, source)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("0.3.0", "0.4.0")
      expect(response.body).to include('data-test="source-versions-list"')
    end

    it "member assegnato (lettura = visibilità del progetto) → 200" do
      sign_in(member)
      get member_project_source_versions_path(project, source)
      expect(response).to have_http_status(:ok)
    end

    it "fonte senza cronologia → 200 con stato vuoto" do
      sign_in(owner)
      get member_project_source_versions_path(project, source)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="source-versions-empty"')
    end
  end

  describe "anti-BOLA" do
    it "fonte di un altro progetto → RecordNotFound (404)" do
      other_project = create(:project, organization: org)
      other_source = create(:project_source, project: other_project, tool_code: "closeyourit-js")

      sign_in(owner)
      get member_project_source_versions_path(project, other_source)
      expect(response).to have_http_status(:not_found)
    end

    it "progetto non visibile al member (non assegnato) → RecordNotFound (404)" do
      hidden = create(:project, organization: org)
      hidden_source = create(:project_source, project: hidden, tool_code: "closeyourit-js")

      sign_in(member)
      get member_project_source_versions_path(hidden, hidden_source)
      expect(response).to have_http_status(:not_found)
    end

    it "progetto di un'altra org → RecordNotFound (404)" do
      other_org = create(:organization)
      foreign = create(:project, organization: other_org)
      foreign_source = create(:project_source, project: foreign, tool_code: "closeyourit-js")

      sign_in(owner)
      get member_project_source_versions_path(foreign, foreign_source)
      expect(response).to have_http_status(:not_found)
    end
  end
end
