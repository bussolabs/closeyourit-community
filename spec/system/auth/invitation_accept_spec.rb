# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invitation accept", type: :system do
  before { driven_by(:rack_test) }

  let(:invitation) { create(:invitation, email: "new@example.com", role: :admin) }

  it "mostra email/organizzazione read-only e accetta impostando nome+password" do
    token = invitation.generate_token_for(:invitation)
    visit edit_invitation_path(token)

    expect_test "invite-organization"
    expect(page).to have_css("[data-test='invite-email']", text: "new@example.com")

    fill_test "invite-name", with: "Bob"
    fill_test "invite-password", with: "Secret123!"
    fill_test "invite-password-confirmation", with: "Secret123!"
    click_on_test "invite-submit"

    expect(page).to have_current_path(root_path)
    expect_test "home-queue-bar"
  end
end
