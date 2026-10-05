# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets piattaforme", type: :request do
  let(:org) { create(:organization) }
  let(:admin) { create(:account) }
  let(:ios) { create(:platform, organization: org, code: "ios") }
  let(:web) { create(:platform, organization: org, code: "web") }
  # progetto che dichiara SOLO ios
  let(:project) { create(:project, organization: org).tap { |p| p.platforms << ios } }
  let(:status) { create(:ticket_status, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }

  before { create(:membership, account: admin, organization: org, role: :owner) }

  def sign_in(acc)
    post login_path, params: { email: acc.email, password: "Secret123!" }
  end

  def base_params(extra = {})
    {
      project_id: project.id, title: "Bug",
      scenarios_attributes: [ { step_given: "g", step_when: "w", step_then: "t", step_expected: "e" } ],
      status_id: status.id, priority_id: priority.id
    }.merge(extra)
  end

  it "crea con una piattaforma del progetto → associata" do
    sign_in(admin)
    post member_tickets_path, params: base_params(platform_ids: [ "", ios.id ])
    expect(Ticketing::Ticket.find_by(title: "Bug").platforms).to contain_exactly(ios)
  end

  it "piattaforma fuori dal progetto → 422" do
    sign_in(admin)
    post member_tickets_path, params: base_params(platform_ids: [ "", web.id ])
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "senza piattaforme → ok (platform-agnostico)" do
    sign_in(admin)
    post member_tickets_path, params: base_params
    expect(Ticketing::Ticket.find_by(title: "Bug").platforms).to be_empty
  end

  it "update sincronizza le piattaforme colpite" do
    sign_in(admin)
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)
    patch member_ticket_path(ticket), params: base_params(platform_ids: [ "", ios.id ])
    expect(ticket.reload.platforms).to contain_exactly(ios)
  end

  it "update con piattaforma fuori dal progetto → 422" do
    sign_in(admin)
    ticket = create(:ticket, organization: org, project: project, status: status, priority: priority)
    patch member_ticket_path(ticket), params: base_params(platform_ids: [ "", web.id ])
    expect(response).to have_http_status(:unprocessable_content)
  end
end
