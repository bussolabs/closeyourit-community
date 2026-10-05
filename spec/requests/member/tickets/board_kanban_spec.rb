# frozen_string_literal: true

require "rails_helper"

# K9–K14 — the ticket board is one panel built with Ui::KanbanComponent, and a search shows itself in
# the columns: "found / total", columns without a match collapsed, the searched words highlighted.
RSpec.describe "Member::Tickets board as a kanban panel (K9-K14)", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let!(:open) { create(:ticket_status, organization: org, code: "open", label: "Open", position: 1) }
  let!(:review) { create(:ticket_status, organization: org, code: "review", label: "Review", position: 2) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account: account, organization: org, role: :owner) }
  end

  before { post login_path, params: { email: owner.email, password: "Secret123!" } }

  def html = Capybara.string(response.body)

  # The board runs one query per column on purpose (LIMIT per block, CYRA-390): with two columns
  # Prosopite would read the two look-alike queries as an N+1.
  def get_board(**params) = allow_n_plus_one { get member_tickets_path, params: params }

  it "puts the filter bar and the columns in one white panel (T1, K9)" do
    get_board

    panel = html.find("[data-test='board-panel'].bg-white")
    expect(panel).to have_css("[data-test='board-toolbar']")
    expect(panel).to have_css("[data-test='board-column-open'].bg-stone-50")
    expect(panel).to have_css("[data-test='board-column-review']")
  end

  context "with a search on" do
    before do
      create(:ticket, organization: org, project: project, status: open, title: "Webhook retries duplicate orders")
      create(:ticket, organization: org, project: project, status: open, title: "Login fails")
      create(:ticket, organization: org, project: project, status: review, title: "Slow export")
      get_board(q: "webhook", semantic: "0")
    end

    it "counts found / total in each column (K11)" do
      column = html.find("[data-test='board-column-open']")
      expect(column.find("[data-test='board-count-open']").text).to eq("1")
      expect(column).to have_css("[data-board-total]", text: "2")
    end

    it "collapses the columns without a match, without touching the saved choice (K12)" do
      expect(html.find("[data-test='board-column-review']")["data-collapsed"]).to eq("true")
      expect(html.find("[data-test='board-column-review']")["data-auto-collapsed"]).to eq("true")
      expect(html.find("[data-test='board-column-open']")["data-collapsed"]).to eq("false")
      expect(owner.reload.board_columns_configured?).to be(false)
    end

    it "highlights the searched word in the card titles (K13)" do
      expect(html).to have_css("[data-test='board-card-title'] mark", text: "Webhook")
    end
  end

  it "shows only the total and collapses nothing on its own without a search" do
    create(:ticket, organization: org, project: project, status: open, title: "Webhook retries")
    get_board

    expect(html.find("[data-test='board-count-open']").text).to eq("1")
    expect(html).to have_no_css("[data-board-total]")
    expect(html).to have_no_css("[data-auto-collapsed]")
    expect(html).to have_no_css("[data-test='board-card-title'] mark")
  end
end
