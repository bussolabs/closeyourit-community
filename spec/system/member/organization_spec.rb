# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member organization settings", type: :system do
  before { driven_by(:rack_test) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "un admin con members.view vede il link Members ma non Organization (owner-only)" do
    org = create(:organization)
    owner = create(:account)
    create(:membership, account: owner, organization: org, role: :owner)
    admin = create(:account)
    create(:membership, account: admin, organization: org, role: :admin)
    # admin (demoto) vede i membri solo col permesso esplicito; Organization resta owner-only.
    Authorization::SetAccountPermissions.call(
      organization: org, account: admin, allow_keys: [ "members.view" ], actor: owner
    )

    sign_in_as(admin)

    # sidebar: link membri sì, link organizzazione no
    visit member_members_path
    expect(page).to have_css("[data-test='member-nav-members']")
    expect(page).not_to have_css("[data-test='member-nav-organization']")
  end

  it "l'owner rinomina l'organizzazione" do
    owner = create(:account)
    org = create(:organization, name: "Old Co", slug: "old-co")
    create(:membership, account: owner, organization: org, role: :owner)

    sign_in_as(owner)
    visit edit_member_organization_path
    expect_test "member-organization-form"

    fill_test "organization-name", with: "New Co"
    click_on_test "member-organization-submit"
    conferma_azione_pericolosa

    expect_test "flash-notice"
    expect(org.reload.name).to eq("New Co")
  end

  it "l'owner imposta la vista progetti predefinita dell'organizzazione" do
    owner = create(:account)
    org = create(:organization, name: "Acme", slug: "acme")
    create(:membership, account: owner, organization: org, role: :owner)

    sign_in_as(owner)
    visit edit_member_organization_path
    click_on_test "org-default-view-table"
    click_on_test "member-organization-submit"
    conferma_azione_pericolosa

    expect_test "flash-notice"
    expect(org.reload.default_projects_view).to eq("table")
  end
end
