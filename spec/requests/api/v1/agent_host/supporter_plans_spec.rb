# frozen_string_literal: true

require "rails_helper"

# CYRA-1193 — the machine asks for the next plan its supporter should judge, then sends the verdict.
RSpec.describe "Api::V1::AgentHost::SupporterPlans", type: :request do
  let(:organization) { create(:organization) }
  let(:service_account) do
    create(:account, :service).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end
  let(:host) { create(:agent_host, organization:, service_account:) }
  let(:plain) { "cyi_ah_plain_supporter_plan_value" }
  let(:headers) { { "Authorization" => "Bearer #{plain}" } }
  let(:project) { create(:project, organization:, supporter_enabled: true) }
  let(:ticket) { create(:ticket, organization:, project:, title: "Sort the list by name", with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow.tap { |w| w.update!(triaged_at: 2.minutes.ago, planned_at: 1.minute.ago) } }

  before { create(:agent_host_token, host:, token_digest: Digest::SHA256.hexdigest(plain)) }

  def create_plan
    attempt = create(:agent_attempt, organization:, workflow:)
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Sort the list in the index view.", scenarios: [],
                         definition_of_done: [ "The list is sorted" ], notes: [], ticket_snapshot_digest: "snapshot")
  end

  it "answers 204 when no plan waits" do
    get "/api/v1/agent_host/supporter_plan", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  it "serves the plan and approves it on an accepted verdict" do
    plan = create_plan

    get "/api/v1/agent_host/supporter_plan", headers: headers
    item = response.parsed_body["data"]
    expect(item).to include("plan_id" => plan.id, "project_key" => project.key, "autonomous_max" => 6)
    expect(item["plan"]).to include("version" => plan.version)
    expect(item["plan"]["document"]).to include("Sort the list", "The list is sorted")

    post "/api/v1/agent_host/supporter_plans/#{plan.id}/verdict", headers: headers, as: :json, params: {
      digest: item["digest"],
      verdict: { recommendation: "approve", risk_score: 2, confidence: "high", touched_paths: [ "app/views/items/index.html.erb" ],
                 sources: [ "README.md" ], rationale: "r", reasons_against: "a", assumptions: "s", undo: "u" }
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]["outcome"]).to eq("approved")
    expect(workflow.reload.approved_at).to be_present

    get "/api/v1/agent_host/supporter_plan", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  # CYRA-1197
  it "does not serve a plan of a project the machine does not follow" do
    host.update!(repositories: [ "OTHER" ])
    create_plan

    get "/api/v1/agent_host/supporter_plan", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  it "does not serve a plan of a project with the supporter off" do
    project.update!(supporter_enabled: false)
    create_plan

    get "/api/v1/agent_host/supporter_plan", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  it "does not serve a plan it already judged at that version" do
    plan = create_plan
    Agents::SupporterDecision.create!(organization:, workflow:, target_type: "plan", target_id: plan.id,
                                      target_digest: Agents::Supporters::NextPlan.digest(plan), outcome: "escalated",
                                      engine: "codex", risk_score: 7)

    get "/api/v1/agent_host/supporter_plan", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  # CYRA-1197 — plans escalated before the supporter could send them back are read once more.
  it "serves again a plan judged with an older version of the rules" do
    plan = create_plan
    old = "sha256:" + Digest::SHA256.hexdigest(JSON.generate([ plan.id, plan.version,
                                                               Agents::Supporters::NextPlan.document(plan) ]))
    Agents::SupporterDecision.create!(organization:, workflow:, target_type: "plan", target_id: plan.id,
                                      target_digest: old, outcome: "escalated", engine: "codex", risk_score: 7)

    get "/api/v1/agent_host/supporter_plan", headers: headers
    expect(response).to have_http_status(:ok)
  end

  # The oldest plans may all be judged already (escalated to a person): the supporter must still reach the
  # newer ones behind them instead of answering "nothing to judge".
  it "serves a newer plan when the older ones are all judged already" do
    judged = Prosopite.pause { Array.new(21) { |index| judged_plan(index) } }
    fresh = create_plan

    get "/api/v1/agent_host/supporter_plan", headers: headers

    expect(judged.size).to eq(21)
    expect(response.parsed_body.dig("data", "plan_id")).to eq(fresh.id)
  end

  def judged_plan(index)
    other = create(:ticket, organization:, project:, with_agent_workflow: true).agent_workflow
    other.update!(triaged_at: 1.hour.ago, planned_at: (60 - index).minutes.ago)
    attempt = create(:agent_attempt, organization:, workflow: other)
    plan = Agents::Plan.create!(workflow: other, attempt:, technical_analysis: "Bump a dependency.", scenarios: [],
                                definition_of_done: [ "Audit is clean" ], notes: [], ticket_snapshot_digest: "s")
    Agents::SupporterDecision.create!(organization:, workflow: other, target_type: "plan", target_id: plan.id,
                                      target_digest: Agents::Supporters::NextPlan.digest(plan), outcome: "escalated",
                                      engine: "codex", risk_score: 7)
  end

  it "refuses an uncertified host" do
    host.update!(certified_at: nil)
    get "/api/v1/agent_host/supporter_plan", headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "refuses a request without a host token" do
    post "/api/v1/agent_host/supporter_plans/#{SecureRandom.uuid}/verdict", as: :json, params: {}
    expect(response).to have_http_status(:unauthorized)
  end
end
