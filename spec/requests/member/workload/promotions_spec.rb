# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Workload::Actions::Promotions", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:team) { create(:team, organization: org) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: account, organization: org, role: :member)
    create(:team_membership, team: team, account: account)
    create(:team_project_access, team: team, project: project)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  it "GET new → 200" do
    sign_in(account)
    action = create(:workload_action, team: team, organization: org)

    get new_member_workload_action_promotion_path(action)

    expect(response).to have_http_status(:ok)
  end

  it "POST create genera il ticket, salva il backlink e reindirizza al ticket" do
    sign_in(account)
    action = create(:workload_action, team: team, organization: org, title: "Firma accordo")

    expect do
      post member_workload_action_promotion_path(action), params: { project_id: project.id, description: "API esterno" }
    end.to change(Ticketing::Ticket, :count).by(1)

    ticket = Ticketing::Ticket.last
    expect(ticket.project).to eq(project)
    expect(action.reload.ticket).to eq(ticket)
    expect(response).to redirect_to(member_ticket_path(ticket))
  end

  it "action già linkata → redirect alla show, nessun nuovo ticket" do
    sign_in(account)
    action = create(:workload_action, :with_ticket, team: team, organization: org)

    expect do
      post member_workload_action_promotion_path(action), params: { project_id: project.id }
    end.not_to change(Ticketing::Ticket, :count)

    expect(response).to redirect_to(member_workload_action_path(action))
  end

  it "action di un altro team → 404 (anti-BOLA)" do
    sign_in(account)
    other = create(:workload_action, organization: org)

    get new_member_workload_action_promotion_path(other)

    expect(response).to have_http_status(:not_found)
  end
end
