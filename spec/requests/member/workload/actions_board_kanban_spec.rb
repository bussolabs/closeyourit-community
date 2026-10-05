# frozen_string_literal: true

require "rails_helper"

# K9–K14 — the Workload actions board is the same kanban panel as the ticket board.
RSpec.describe "Member::Workload::Actions board as a kanban panel (K9-K14)", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:team) { create(:team, organization: org) }

  before do
    create(:membership, account: account, organization: org, role: :member)
    create(:team_membership, team: team, account: account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def html = Capybara.string(response.body)

  it "puts the filter bar and the columns in one white panel (T1, K9)" do
    get member_workload_actions_path

    panel = html.find("[data-test='workload-board-panel'].bg-white")
    expect(panel).to have_css("[data-test='workload-board-toolbar']")
    expect(panel).to have_css("[data-test='workload-board-column-planned'].bg-stone-50")
  end

  context "with a search on" do
    before do
      create(:workload_action, team: team, organization: org, status: :planned, title: "Trade fair booth")
      create(:workload_action, team: team, organization: org, status: :planned, title: "Print flyers")
      create(:workload_action, team: team, organization: org, status: :in_progress, title: "Call the venue")
      get member_workload_actions_path, params: { q: "fair" }
    end

    it "counts found / total in each column (K11)" do
      column = html.find("[data-test='workload-board-column-planned']")
      expect(column.find("[data-test='workload-board-count-planned']").text).to eq("1")
      expect(column).to have_css("[data-board-total]", text: "2")
    end

    it "collapses the columns without a match (K12)" do
      expect(html.find("[data-test='workload-board-column-in_progress']")["data-collapsed"]).to eq("true")
      expect(html.find("[data-test='workload-board-column-planned']")["data-collapsed"]).to eq("false")
    end

    it "highlights the searched word in the card titles (K13)" do
      expect(html).to have_css("[data-test='workload-board-column-planned'] mark", text: "fair")
    end
  end
end
