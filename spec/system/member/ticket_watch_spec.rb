# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member ticket watching", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:member) { create(:account, name: "Marco Rossi") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let(:ticket) { create(:ticket, :story, organization: org, project: project, title: "Wishlist sharing") }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "segue e poi smette di seguire il ticket dalla show" do
    ticket
    sign_in_as(member)
    visit member_ticket_path(ticket)

    expect { click_on_test "ticket-watch" }.to change { ticket.subscriptions.count }.from(0).to(1)
    expect_test "flash-notice"
    # Il bottone ora è in stato "seguito" (DELETE) → un secondo click disiscrive.
    expect_test "ticket-unwatch"

    expect { click_on_test "ticket-unwatch" }.to change { ticket.subscriptions.count }.from(1).to(0)
    expect_test "ticket-watch"
  end

  it "mantiene uno shape bordato coerente tra i due stati Segui/Seguendo (CYRA-66)" do
    ticket
    sign_in_as(member)
    visit member_ticket_path(ticket)

    # Non-seguito: il pulsante Segui ha il bordo.
    expect(page).to have_css("[data-test='ticket-watch'].border")

    click_on_test "ticket-watch"

    # Seguito: resta bordato (non passa a un variant senza bordo → shape stabile).
    expect(page).to have_css("[data-test='ticket-unwatch'].border")
  end
end
