# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member invitation", type: :system do
  before { driven_by(:rack_test) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    sign_in_as(owner)
  end

  it "l'owner invita un membro dalla pagina dedicata" do
    visit member_members_path
    click_on_test "member-invite"
    expect_test "member-invite-form"

    fill_test "invite-email", with: "new@example.com"
    click_on_test "member-invite-submit"

    expect(page).to have_current_path(member_members_path)
    expect_test "flash-notice"
    expect(page).to have_content("new@example.com")
    expect(org.invitations.pending.where(email: "new@example.com")).to exist
  end

  it "mostra l'errore se l'email è già un membro e resta sul form" do
    existing = create(:account, email: "already@example.com")
    create(:membership, account: existing, organization: org, role: :member)

    visit new_member_invitation_path
    fill_test "invite-email", with: "already@example.com"
    click_on_test "member-invite-submit"

    expect_test "member-invite-form"
    expect_test "member-invite-error"
  end

  it "reinvia un invito pendente" do
    org.invitations.create!(email: "pending@example.com", role: :member)
    visit member_members_path

    expect do
      click_on_test "member-invitation-resend"
    end.to have_enqueued_mail(Connections::InvitationsMailer, :invite)

    expect(page).to have_current_path(member_members_path)
    expect_test "flash-notice"
  end

  it "revoca un invito pendente" do
    invitation = org.invitations.create!(email: "pending@example.com", role: :member)
    visit member_members_path

    # CYRA-924 — the row button opens a <dialog> (no JS under rack_test): its red button is reached with visible: :all (F16).
    expect(page).to have_css("[data-test='member-invitation-revoke'][data-action='ui--dialog#open']")
    find("[data-test='member-invitation-revoke-dialog-#{invitation.id}-confirm']", visible: :all).click

    expect(page).to have_current_path(member_members_path)
    expect(Connections::Invitation).not_to exist(invitation.id)
  end
end
