# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ticket filters from area overviews", type: :request do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization:) }
  let(:hidden_project) { create(:project, organization:) }
  let(:status) { create(:ticket_status, organization:, category: :open) }

  before do
    create(:membership, account:, organization:, role: :member)
    create(:project_membership, account:, project:)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def ticket_codes
    Nokogiri::HTML(response.body).css("a[href^='/member/tickets/']").map(&:text).join(" ")
  end

  it "combines unassigned and overdue without exposing inaccessible projects" do
    wanted = create(:ticket, :story, organization:, project:, status:, due_at: 1.day.ago, assignee: nil)
    assigned = create(:ticket, :story, organization:, project:, status:, due_at: 1.day.ago, assignee: account)
    future = create(:ticket, :story, organization:, project:, status:, due_at: 1.day.from_now, assignee: nil)
    hidden = create(:ticket, :story, organization:, project: hidden_project, status:, due_at: 1.day.ago, assignee: nil)

    get list_member_tickets_path, params: { ft: 1, unassigned: "1", overdue: "1" }

    expect(response).to have_http_status(:ok)
    expect(ticket_codes).to include(wanted.code)
    expect(ticket_codes).not_to include(assigned.code, future.code, hidden.code)
  end

  it "shows only open blocked workflows and preserves the project boundary" do
    blocked = create(:ticket, :story, organization:, project:, status:)
    active = create(:ticket, :story, organization:, project:, status:)
    finished = create(:ticket, :story, organization:, project:, status:)
    hidden = create(:ticket, :story, organization:, project: hidden_project, status:)
    [ blocked, hidden ].each { |ticket| create(:agent_workflow, ticket:, blocked_at: Time.current, blocked_kind: "attempt_limit") }
    create(:agent_workflow, ticket: active)
    create(:agent_workflow, ticket: finished, blocked_at: 1.day.ago, blocked_kind: "attempt_limit", completed_at: Time.current)

    get list_member_tickets_path, params: { ft: 1, workflow: "blocked" }

    expect(response).to have_http_status(:ok)
    expect(ticket_codes).to include(blocked.code)
    expect(ticket_codes).not_to include(active.code, finished.code, hidden.code)
  end
end
