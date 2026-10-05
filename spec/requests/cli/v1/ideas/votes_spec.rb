# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Ideas::Votes", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:idea) { create(:idea, organization:, project:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  it "senza bearer → 401" do
    put "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/vote"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "vota (PUT) → 200, voted true, idempotente" do
      expect do
        put "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/vote", headers: headers
      end.to change { idea.reload.votes_count }.from(0).to(1)
      expect(response.parsed_body["data"]).to include("voted" => true, "votes_count" => 1, "idea_id" => idea.id)

      expect do
        put "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/vote", headers: headers
      end.not_to change { idea.reload.votes_count }
    end

    it "rimuove il voto (DELETE) → voted false, idempotente" do
      put "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/vote", headers: headers

      expect do
        delete "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/vote", headers: headers
      end.to change { idea.reload.votes_count }.from(1).to(0)
      expect(response.parsed_body["data"]["voted"]).to be(false)

      delete "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/vote", headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "idea congelata → 422 R422-IDEA-002, nessun voto" do
      frozen = create(:idea, :archived, organization:, project:)

      expect do
        put "/cli/v1/projects/#{project.id}/ideas/#{frozen.id}/vote", headers: headers
      end.not_to change { frozen.reload.votes_count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-IDEA-002")
    end
  end
end
