# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Coworkers runs and proposals", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: organization, key: "SHOP") }
  let(:ticket) { create(:ticket, project: project, title: "Checkout fails") }

  before do
    create(:membership, account: owner, organization: organization, role: :owner)
    create(:membership, account: member, organization: organization, role: :member)
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
  end

  def headers_for(account)
    secret = Accounts::ApiTokens::Issue.call(account: account, organization: organization, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{secret}" }
  end

  describe "stopping a run" do
    let(:team_puck) do
      Coworkers::Puck.create!(organization: organization, account: owner, name: "Shop triage", instructions: "Help",
                              visibility: "team", project: project)
    end
    let(:run) { team_puck.runs.create!(kind: "chat", input: "Hello", account: owner) }

    it "lets the requester stop the run" do
      patch "/cli/v1/coworkers/#{team_puck.id}/runs/#{run.id}", headers: headers_for(owner), as: :json
      expect(response).to have_http_status(:ok)
      expect(run.reload.stop_requested).to be(true)
    end

    it "refuses a member who sees the Puck but neither asked for the run nor manages the Puck" do
      create(:project_membership, project: project, account: member)
      get "/cli/v1/coworkers/#{team_puck.id}/runs/#{run.id}", headers: headers_for(member), as: :json
      expect(response).to have_http_status(:ok)
      patch "/cli/v1/coworkers/#{team_puck.id}/runs/#{run.id}", headers: headers_for(member), as: :json
      expect(response).to have_http_status(:not_found)
      expect(run.reload.stop_requested).to be(false)
    end
  end

  describe "proposals" do
    let(:puck) { Coworkers::Puck.create!(account: owner, organization: organization, name: "Triage", instructions: "Help") }
    let(:run) do
      puck.runs.create!(kind: "chat", input: "Comment please", status: "completed",
                        scope: Coworkers::Scope.capture(account: owner, organization: organization))
    end
    let!(:proposal) do
      Assistant::Proposal.create!(coworkers_run: run, organization: organization, account: owner, kind: :comment_ticket,
                                  payload: { "ticket_id" => ticket.id, "ticket_code" => ticket.code, "ticket_title" => ticket.title, "body" => "On it" })
    end
    let(:headers) { headers_for(owner) }

    it "discards a pending proposal once and leaves a discarded one as it is" do
      post "/cli/v1/coworkers/#{puck.id}/proposals/#{proposal.id}/discard", headers: headers, as: :json
      expect(response.parsed_body["data"]).to eq("id" => proposal.id, "status" => "discarded")
      post "/cli/v1/coworkers/#{puck.id}/proposals/#{proposal.id}/discard", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(proposal.reload).to be_status_discarded
    end

    it "refuses to confirm a proposal that was already discarded" do
      proposal.update!(status: :discarded)
      post "/cli/v1/coworkers/#{puck.id}/proposals/#{proposal.id}/confirm", headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(ticket.comments).to be_empty
    end
  end
end
