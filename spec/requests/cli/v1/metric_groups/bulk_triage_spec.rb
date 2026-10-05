# frozen_string_literal: true

require "rails_helper"

# CYRA-45: triage bulk delle metriche via CLI (equivalente del bottone bulk della lista Member).
RSpec.describe "Cli::V1::MetricGroups bulk_triage", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  it "senza bearer → 401" do
    create(:membership, account:, organization:, role: :owner)
    post "/cli/v1/projects/#{project.id}/metric_groups/bulk_triage", params: { ids: [], bulk_action: "resolve" }
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (gestisce le metriche di tutto)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "resolve → 200, i gruppi diventano resolved, meta.updated" do
      a = create(:metric_group, project:, status: :unresolved)
      b = create(:metric_group, project:, status: :unresolved)

      post "/cli/v1/projects/#{project.id}/metric_groups/bulk_triage",
           params: { ids: [ a.id, b.id ], bulk_action: "resolve" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["meta"]["updated"]).to eq(2)
      expect(a.reload.status).to eq("resolved")
      expect(b.reload.status).to eq("resolved")
    end

    it "ignore → ignored" do
      a = create(:metric_group, project:, status: :unresolved)
      post "/cli/v1/projects/#{project.id}/metric_groups/bulk_triage",
           params: { ids: [ a.id ], bulk_action: "ignore" }, headers: headers
      expect(a.reload.status).to eq("ignored")
    end

    it "anti-BOLA: id di un altro progetto viene scartato (resta invariato)" do
      mine = create(:metric_group, project:, status: :unresolved)
      other = create(:metric_group, project: create(:project, organization:), status: :unresolved)

      post "/cli/v1/projects/#{project.id}/metric_groups/bulk_triage",
           params: { ids: [ mine.id, other.id ], bulk_action: "resolve" }, headers: headers

      expect(response.parsed_body["meta"]["updated"]).to eq(1)
      expect(mine.reload.status).to eq("resolved")
      expect(other.reload.status).to eq("unresolved")
    end

    it "azione non valida → 422 R422-METRIC-005, nulla cambia" do
      a = create(:metric_group, project:, status: :unresolved)
      post "/cli/v1/projects/#{project.id}/metric_groups/bulk_triage",
           params: { ids: [ a.id ], bulk_action: "bogus" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-METRIC-005")
      expect(a.reload.status).to eq("unresolved")
    end
  end

  context "member che vede il progetto ma senza metrics.promote" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "→ 403 (gate metrics.promote)" do
      a = create(:metric_group, project:, status: :unresolved)
      post "/cli/v1/projects/#{project.id}/metric_groups/bulk_triage",
           params: { ids: [ a.id ], bulk_action: "resolve" }, headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(a.reload.status).to eq("unresolved")
    end
  end
end
