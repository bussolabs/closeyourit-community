# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member members", type: :system do
  before { driven_by(:rack_test) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def kebab_action(email, action)
    within("tr", text: email) do
      find("[data-test='member-member-menu']", visible: :all).click
      find("[data-test='#{action}']", visible: :all).click
    end
  end

  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    sign_in_as(owner)
  end

  it "l'owner vede la lista membri" do
    visit member_members_path
    expect_test "member-members"
    expect(page).to have_css("[data-test='member-member-row']", minimum: 1)
  end

  it "promuove un member ad admin dal kebab" do
    member = create(:account, email: "sara@example.com")
    member_m = create(:membership, account: member, organization: org, role: :member)

    visit member_members_path
    kebab_action("sara@example.com", "member-member-role")
    conferma_azione_pericolosa

    expect(page).to have_current_path(member_members_path)
    expect(member_m.reload).to be_admin
  end

  it "rimuove un membro dal kebab" do
    member = create(:account, email: "bye@example.com")
    member_m = create(:membership, account: member, organization: org, role: :member)

    visit member_members_path
    # CYRA-924 — removal opens a <dialog> (no JS under rack_test): its red button is reached with visible: :all (F16).
    find("[data-test='member-remove-dialog-#{member_m.id}-confirm']", visible: :all).click

    expect(page).to have_current_path(member_members_path)
    expect(Connections::Membership).not_to exist(member_m.id)
  end

  it "declassa un admin a member dal kebab" do
    admin_account = create(:account, email: "adm@example.com")
    admin_m = create(:membership, account: admin_account, organization: org, role: :admin)

    visit member_members_path
    kebab_action("adm@example.com", "member-member-role")
    conferma_azione_pericolosa

    expect(page).to have_current_path(member_members_path)
    expect(admin_m.reload).to be_member
  end

  it "allows an owner to update a member name while keeping the email read-only" do
    member = create(:account, name: "Sara Old", email: "sara@example.com")
    create(:membership, account: member, organization: org, role: :member)

    visit member_members_path
    kebab_action("sara@example.com", "member-member-edit")

    expect(page).to have_css("[data-test='member-edit-form']")
    fill_test "member-name", with: "Sara New"
    expect(page).to have_css("[data-test='member-email'][readonly]")
    click_on_test "member-edit-submit"

    expect(page).to have_current_path(member_members_path)
    member.reload
    expect(member.name).to eq("Sara New")
    expect(member.email).to eq("sara@example.com")
  end

  it "un member semplice senza permesso non vede la pagina membri (gate + nav assente)" do
    plain = create(:account, email: "plain@example.com")
    create(:membership, account: plain, organization: org, role: :member)

    sign_in_as(plain)
    visit member_members_path

    expect(page).not_to have_css("[data-test='member-members']")
    expect(page).to have_current_path(root_path)
    expect(page).not_to have_css("[data-test='member-nav-members']")
  end

  it "un member con members.view vede la lista in sola lettura (niente invito né kebab)" do
    plain = create(:account, email: "plain@example.com")
    create(:membership, account: plain, organization: org, role: :member)
    Authorization::SetAccountPermissions.call(
      organization: org, account: plain, allow_keys: [ "members.view" ], actor: owner
    )

    sign_in_as(plain)
    visit member_members_path

    expect_test "member-members"
    expect(page).to have_css("[data-test='member-nav-members']")
    expect(page).not_to have_css("[data-test='member-invite']")
    expect(page).not_to have_css("[data-test='member-member-menu']")
  end

  it "il filtro per ruolo riduce le righe mostrate" do
    create(:membership, account: create(:account), organization: org, role: :admin)
    create(:membership, account: create(:account), organization: org, role: :member)
    create(:membership, account: create(:account), organization: org, role: :member)

    visit member_members_path
    total_rows = page.all("[data-test='member-member-row']").size

    # rack_test non guida il widget Stimulus: navigo direttamente con il filtro applicato.
    visit member_members_path(role: [ "admin" ])
    filtered_rows = page.all("[data-test='member-member-row']").size

    expect(filtered_rows).to be < total_rows
    expect(filtered_rows).to eq(1)
    expect(page).to have_css("[data-test='member-role-admin']")
  end

  it "mostra il footer di paginazione dei membri" do
    visit member_members_path
    expect(page).to have_css("[data-test='members-pagination']")
  end
end
