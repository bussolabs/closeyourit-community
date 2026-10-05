# frozen_string_literal: true

require "rails_helper"

# CYRA-883 — the parts of the ticket tabs that work with CSS only: the comments-only filter of the
# discussion and the question options that appear once the field is in use.
RSpec.describe "Member ticket tabs", :js, type: :system do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project:) }
  let(:owner) do
    create(:account).tap do |account|
      create(:membership, :owner, organization: org, account:)
      create(:project_membership, project:, account:)
    end
  end

  it "hides system events when only comments are asked for" do
    create(:ticket_comment, ticket:, author: owner, body: "A person wrote this.")
    event = create(:ticket_event, ticket:)
    sign_in_as(owner)
    visit member_ticket_path(ticket, tab: "discussion")

    expect(page).to have_css("[data-test='member-ticket-event-#{event.id}']")
    find("label", text: I18n.t("member.tickets.comments.filter.only_comments")).click

    expect(page).to have_no_css("[data-test='member-ticket-event-#{event.id}']")
    expect(page).to have_text("A person wrote this.")
  end

  it "shows the question options once the field is in use" do
    sign_in_as(owner)
    visit member_ticket_path(ticket, tab: "questions")

    expect(page).to have_no_css("[data-test='ticket-question-options']")
    find("[data-test='ticket-question-body']").click

    expect(page).to have_css("[data-test='ticket-question-blocking']")
  end
end
