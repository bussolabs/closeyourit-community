# frozen_string_literal: true

require "rails_helper"

# The button on a project's header opens the assistant fixed on that project.
RSpec.describe "Assistant on a project", :js, type: :system do
  let(:org) { create(:organization) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account: account, organization: org, role: :owner) }
  end
  let!(:dashboard) { create(:project, organization: org, key: "DASH", name: "Dashboard") }
  let!(:storefront) { create(:project, organization: org, key: "STR", name: "Storefront") }

  def ask_about(project)
    visit member_project_path(project)
    find("[data-test='project-ask']").click
  end

  it "opens the column on the project and keeps it there after the first question" do
    sign_in_as(owner)
    ask_about(dashboard)

    expect(page).to have_css("[data-test='assistant-panel'] [data-test='assistant-project']", text: "Dashboard", wait: 5)
    expect(page).to have_css("[data-test='assistant-greeting']", text: "Dashboard")

    find("[data-test='assistant-panel'] [data-test='assistant-input']").set("Which errors are open?")
    find("[data-test='assistant-panel'] [data-test='assistant-send']").click

    expect(page).to have_css("[data-test='assistant-panel'] [data-test='assistant-message']", text: "Which errors are open?", wait: 5)
    expect(page).to have_css("[data-test='assistant-panel'] [data-test='assistant-project']", text: "Dashboard")
    expect(Assistant::Conversation.last.project).to eq(dashboard)
  end

  it "moves to another project from that project's button, even after a conversation was created" do
    sign_in_as(owner)
    ask_about(dashboard)
    find("[data-test='assistant-panel'] [data-test='assistant-input']").set("Which errors are open?")
    find("[data-test='assistant-panel'] [data-test='assistant-send']").click
    expect(page).to have_css("[data-test='assistant-panel'] [data-test='assistant-message']", wait: 5)

    ask_about(storefront)

    expect(page).to have_css("[data-test='assistant-panel'] [data-test='assistant-project']", text: "Storefront", wait: 5)
    expect(page).to have_no_css("[data-test='assistant-panel'] [data-test='assistant-message']")
    expect(page).to have_no_css("[data-test='assistant-panel-error']")
  end

  it "goes back to every project from the cross on the project bar" do
    sign_in_as(owner)
    ask_about(dashboard)
    expect(page).to have_css("[data-test='assistant-panel'] [data-test='assistant-project']", wait: 5)

    find("[data-test='assistant-project-clear']").click

    expect(page).to have_no_css("[data-test='assistant-panel'] [data-test='assistant-project']", wait: 5)
    expect(page).to have_css("[data-test='assistant-panel'] [data-test='assistant-input']")
    expect(Assistant::Conversation.last.project).to be_nil
  end
end
