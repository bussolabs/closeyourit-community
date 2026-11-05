# frozen_string_literal: true

require "rails_helper"

# CYRA-1184 — the approvals queue from the terminal (`cyi approvals`): same queue, same card, same
# decisions as the web page, through the same services.
RSpec.describe "Cli::V1::Approvals", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }
  let(:headers) { { "Authorization" => "Bearer #{token_for(owner)}" } }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    organization.update_column(:cto_id, owner.id)
  end

  def token_for(account)
    Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret]
  end

  def planned_workflow(title: "Plan to approve")
    ticket = create(:ticket, organization:, project:, title:)
    workflow = create(:agent_workflow, ticket:, triage_requested_at: 1.hour.ago, triaged_at: 30.minutes.ago,
                                       planned_at: Time.current, ticket_snapshot_digest: "snapshot")
    attempt = create(:agent_attempt, workflow:, organization:)
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Touch the billing job", scenarios: [],
                         definition_of_done: [], notes: [], ticket_snapshot_digest: "snapshot")
    workflow
  end

  def review_ticket
    create(:ticket, organization:, project:, reviewer: owner, title: "Check the delivery",
                    status: create(:ticket_status, :in_review, organization:))
  end

  def data = response.parsed_body["data"]

  it "refuses a call without a bearer token" do
    get "/cli/v1/approvals"

    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index" do
    it "lists the queue with key, state, code and counts" do
      workflow = planned_workflow
      ticket = review_ticket

      get "/cli/v1/approvals", headers: headers

      expect(response).to have_http_status(:ok)
      keys = data.map { |row| row["key"] }
      expect(keys).to contain_exactly("agent_plan:#{workflow.id}", "review:#{ticket.id}")
      row = data.find { |r| r["key"] == "agent_plan:#{workflow.id}" }
      expect(row).to include("kind" => "agent_plan", "state" => "awaiting_approval", "code" => workflow.ticket.code,
                             "subtitle" => "Plan to approve", "deferred_until" => nil)
      expect(row["project"]).to eq("key" => project.key, "name" => project.name)
      expect(response.parsed_body["meta"]).to include("total" => 2)
      expect(response.parsed_body["meta"]["totals"]).to include("awaiting_approval" => 1, "review" => 1)
    end

    it "filters by state" do
      planned_workflow
      ticket = review_ticket

      get "/cli/v1/approvals", params: { state: "review" }, headers: headers

      expect(data.map { |row| row["key"] }).to eq([ "review:#{ticket.id}" ])
    end

    it "marks the rows deferred to tomorrow" do
      workflow = planned_workflow
      Home::Deferrals::Defer.call(account: owner, organization:, card_key: "agent_plan:#{workflow.id}")

      get "/cli/v1/approvals", headers: headers

      expect(data.first["deferred_until"]).to be_present
    end
  end

  describe "GET show" do
    it "returns the card with the plan in markdown and the decisions allowed" do
      workflow = planned_workflow

      get "/cli/v1/approvals/agent_plan/#{workflow.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(data).to include("key" => "agent_plan:#{workflow.id}", "phase" => "awaiting_approval")
      expect(data["decisions"]).to include("approve", "reject", "ask")
      expect(data["plan"]).to include("version" => 1)
      expect(data["plan"]["markdown"]).to include("Touch the billing job")
      expect(data["ticket"]).to include("code" => workflow.ticket.code, "title" => "Plan to approve")
    end

    it "returns the agent questions with their proposed answers" do
      ticket = create(:ticket, organization:, project:, reviewer: owner)
      workflow = create(:agent_workflow, ticket:)
      clarification = create(:agent_clarification, workflow:, questions: [
        { "body" => "Which queue should it use?", "options" => [ { "label" => "default", "recommended" => true } ] }
      ])

      get "/cli/v1/approvals/clarification/#{clarification.id}", headers: headers

      expect(data["decisions"]).to eq([ "reply" ])
      question = data["questions"].first
      expect(question).to include("position" => 1, "body" => "Which queue should it use?")
      expect(question["options"].first).to include("label" => "default", "recommended" => true)
    end

    it "answers 404 for a card of another organization" do
      other = create(:organization)
      foreign = create(:ticket, organization: other, project: create(:project, organization: other))

      get "/cli/v1/approvals/review/#{foreign.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST decision" do
    it "approves a plan" do
      workflow = planned_workflow

      post "/cli/v1/approvals/agent_plan/#{workflow.id}/decision", params: { decision: "approve" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(data).to include("key" => "agent_plan:#{workflow.id}", "decision" => "approve")
      expect(workflow.reload.approved_at).to be_present
    end

    it "refuses a rejection without a reason" do
      workflow = planned_workflow

      post "/cli/v1/approvals/agent_plan/#{workflow.id}/decision", params: { decision: "reject" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-APPROVAL-002")
      expect(workflow.reload.approved_at).to be_nil
    end

    it "sends the plan back with a reason" do
      workflow = planned_workflow

      post "/cli/v1/approvals/agent_plan/#{workflow.id}/decision",
           params: { decision: "reject", text: "Split it in two" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(workflow.reload.approved_at).to be_nil
    end

    it "replies to the agent with the picked answers first" do
      ticket = create(:ticket, organization:, project:, reviewer: owner)
      clarification = create(:agent_clarification, workflow: create(:agent_workflow, ticket:))

      post "/cli/v1/approvals/clarification/#{clarification.id}/decision",
           params: { decision: "reply", answers: { "1" => "default" }, text: "And log it" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(ticket.comments.order(:created_at).last.body).to eq("1. default\nAnd log it")
    end

    it "answers 404 for a card of another organization" do
      other = create(:organization)
      foreign = create(:ticket, organization: other, project: create(:project, organization: other))

      post "/cli/v1/approvals/review/#{foreign.id}/decision", params: { decision: "approve" }, headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST deferral" do
    it "defers the card to tomorrow morning without deciding it" do
      workflow = planned_workflow

      post "/cli/v1/approvals/agent_plan/#{workflow.id}/deferral", headers: headers

      expect(response).to have_http_status(:ok)
      expect(data["until_at"]).to be_present
      expect(Home::Deferral.live_keys_for(owner, organization:)).to include("agent_plan:#{workflow.id}")
      expect(workflow.reload.approved_at).to be_nil
    end

    it "answers 404 for a card that is not mine" do
      post "/cli/v1/approvals/agent_plan/#{SecureRandom.uuid}/deferral", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(Home::Deferral.count).to eq(0)
    end
  end
end
