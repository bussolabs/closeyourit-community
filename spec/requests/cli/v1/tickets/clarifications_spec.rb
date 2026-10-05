# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Clarifications", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:, with_agent_workflow: true) }

  def token_for(acc, org = organization)
    Accounts::ApiTokens::Issue.call(account: acc, organization: org, name: "CLI").value[:secret]
  end

  def path(target = ticket, scope = project)
    "/cli/v1/projects/#{scope.id}/tickets/#{target.id}/clarifications"
  end

  it "senza bearer → 401" do
    create(:membership, account:, organization:)
    get path

    expect(response).to have_http_status(:unauthorized)
  end

  context "membro che vede il progetto (baseline: legge lo stato del suo ticket)" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "un ticket senza domande è pronto" do
      get path, headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["state"]).to eq("ready")
      expect(data["cycles"]).to be_zero
      expect(data["rounds"]).to be_empty
    end

    it "una domanda in sospeso mette in attesa e arriva col suo testo" do
      create(:agent_clarification, workflow: ticket.agent_workflow, questions: [ "Prima?", "Seconda?" ])

      get path, headers: headers

      data = response.parsed_body["data"]
      expect(data["state"]).to eq("waiting")
      expect(data["cycles"]).to eq(1)
      expect(data["has_reply"]).to be(false)
      expect(data["rounds"].sole["cycle"]).to eq(1)
      expect(data["rounds"].sole["questions"]).to eq([ "Prima?", "Seconda?" ])
    end

    it "una lavorazione ferma risulta escalata" do
      create(:agent_clarification, workflow: ticket.agent_workflow)
      ticket.agent_workflow.update!(blocked_at: Time.current, blocked_phase: "triage", blocked_kind: "attempt_limit",
                                    blocked_reason: "review_limit: triage")

      get path, headers: headers

      expect(response.parsed_body["data"]["state"]).to eq("escalated")
    end
  end

  # Anti-BOLA: un ticket fuori dalla visibilità non esiste, non è "vietato" — un 403 direbbe a un
  # estraneo che quel ticket c'è.
  it "un ticket di un progetto non visibile → 404" do
    create(:membership, account:, organization:, role: :member)
    other = create(:project, organization:)
    hidden = create(:ticket, project: other, organization:)

    get path(hidden, other), headers: { "Authorization" => "Bearer #{token_for(account)}" }

    expect(response).to have_http_status(:not_found)
  end
end
