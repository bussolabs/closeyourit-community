# frozen_string_literal: true

require "rails_helper"

# The activity history opens in the same shell as every New: the dark ground, a page header panel
# that holds the close action, and the rows in a panel of their own (T1, T2).
RSpec.describe "Activity history modal shell", type: :request do
  let(:org) { create(:organization) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account:, organization: org, role: :owner) }
  end
  let(:project) { create(:project, organization: org) }

  before { post login_path, params: { email: owner.email, password: "Secret123!" } }

  def expect_standard_shell(page, dialog_test_id)
    dialog = page.at_css("dialog[data-test='#{dialog_test_id}']")
    expect(dialog["class"]).to include("bg-stone-100", "dark:bg-zinc-950", "rounded-xl")
    header = dialog.at_css("header")
    expect(header).to be_present
    expect(header.at_css("[data-test='activity-close']")).to be_present
    expect(dialog.css("[data-test='activity-close']").size).to eq(1)
    expect(dialog.at_css("[data-test='#{dialog_test_id}-panel'] [data-test='activity-panel']")).to be_present
  end

  it "uses the standard shell on a ticket" do
    ticket = create(:ticket, organization: org, project:)

    get member_ticket_path(ticket)

    expect_standard_shell(Nokogiri::HTML(response.body), "ticket-activity-modal")
  end

  it "uses the standard shell on the shared history" do
    idea = create(:idea, organization: org, project:, author: owner)
    Ideas::UpdateIdea.call(idea:, params: { title: "New title", problem: idea.problem }, actor: owner)

    get member_idea_path(idea)

    expect_standard_shell(Nokogiri::HTML(response.body), "activity-modal")
  end
end
