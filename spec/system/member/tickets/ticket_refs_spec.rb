# frozen_string_literal: true

require "rails_helper"

# CYRA-1148 — a ticket code in a comment becomes a label with title and status, but only for the
# tickets the reader can see; the others, and codes inside inline code, stay plain text.
RSpec.describe "Ticket codes in rendered text", type: :system, js: true do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org, key: "SEEN") }
  let(:hidden_project) { create(:project, organization: org, key: "HIDE") }

  it "fills visible codes with a label that opens the ticket" do
    reader = create(:account)
    create(:membership, account: reader, organization: org, role: :member)
    team = create(:team, organization: org)
    create(:team_membership, team:, account: reader)
    create(:team_project_access, team:, project:)
    ticket = create(:ticket, organization: org, project:, title: "Comments page")
    cited = create(:ticket, organization: org, project:, title: "Export drops a row")
    hidden = create(:ticket, organization: org, project: hidden_project, title: "Secret plan")
    create(:ticket_comment, organization: org, ticket:,
                            body: "Same as #{cited.code}, unlike #{hidden.code} and `#{cited.code}`.")
    sign_in_as(reader)

    visit member_ticket_path(ticket, tab: "discussion")

    expect(page).to have_css("a[data-test='ticket-ref']", text: "Export drops a row", count: 1)
    expect(page).to have_text(hidden.code)
    expect(page).to have_no_text("Secret plan")
    expect(page).to have_css("code", text: cited.code)

    find("a[data-test='ticket-ref']").click
    expect(page).to have_current_path(member_ticket_path(cited))
  end
end
