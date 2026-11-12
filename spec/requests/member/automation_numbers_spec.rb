# frozen_string_literal: true

require "rails_helper"

# The numbers of the automatic round: one table, a row per project, the last 30 days.
RSpec.describe "Member::AutomationNumbers", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let!(:alpha) { create(:project, organization: org, name: "Alpha") }
  let!(:beta) { create(:project, organization: org, name: "Beta") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def finished(project, approved_by: nil)
    ticket = create(:ticket, organization: org, project:, with_agent_workflow: true)
    ticket.agent_workflow.update!(completed_at: 1.day.ago, created_at: 1.day.ago - 3.hours, approved_by:)
  end

  # A method, not a let: one example reads two responses.
  def doc = Nokogiri::HTML(response.body)

  def row_names = doc.css("[data-test='automation-numbers-row'] [data-test='automation-numbers-project']").map { |node| node.text.strip }

  it "sends an anonymous visitor to the login" do
    get member_automation_numbers_path
    expect(response).to redirect_to(login_path)
  end

  it "keeps out a member without the agents permission" do
    sign_in(member)
    get member_automation_numbers_path
    expect(response).to have_http_status(:redirect)
  end

  it "shows a row per project with its numbers, and a dash where there is nothing to divide" do
    finished(alpha)
    finished(alpha, approved_by: owner)
    sign_in(owner)
    get member_automation_numbers_path

    expect(response).to have_http_status(:ok)
    expect(row_names).to eq(%w[Alpha Beta])
    rows = doc.css("[data-test='automation-numbers-row']")
    expect(rows.first.at_css("[data-test='automation-numbers-completed']").text.strip).to eq("2")
    expect(rows.first.at_css("[data-test='automation-numbers-hands-off']").text.strip).to eq("50%")
    expect(rows.first.at_css("[data-test='automation-numbers-lead']").text.strip).to include("3")
    expect(rows.last.at_css("[data-test='automation-numbers-completed']").text.strip).to eq("0")
    expect(rows.last.at_css("[data-test='automation-numbers-hands-off']").text.strip).to eq("—")
  end

  it "sorts the rows by a number, the projects without it last" do
    finished(beta)
    sign_in(owner)
    get member_automation_numbers_path, params: { sort: "-hands_off" }

    expect(row_names).to eq(%w[Beta Alpha])
  end

  it "narrows the rows by project name and keeps the bar when nothing matches" do
    sign_in(owner)
    get member_automation_numbers_path, params: { q: "bet" }
    expect(row_names).to eq(%w[Beta])

    get member_automation_numbers_path, params: { q: "zzz" }
    expect(doc.at_css("[data-test='automation-numbers-no-match']")).to be_present
    expect(doc.at_css("[data-test='automation-numbers-toolbar']")).to be_present
  end

  it "renders in English too" do
    sign_in(owner)
    get member_automation_numbers_path, params: { locale: "en" }
    expect(response).to have_http_status(:ok)
  end
end
