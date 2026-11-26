# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — each person writes their GitHub name in the profile: a GitHub assignee becomes theirs.
RSpec.describe "Member::Preferences — GitHub name", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account:, organization: org, role: :member) }

  before { post login_path, params: { email: account.email, password: "Secret123!" } }

  it "saves the GitHub name, without the leading @" do
    patch member_preferences_path, params: { preferences_form: "1", github_login: "@mario-rossi" }

    expect(response).to redirect_to(member_preferences_path)
    expect(account.reload.github_login).to eq("mario-rossi")
  end

  it "an empty field removes it" do
    account.update!(github_login: "mario-rossi")

    patch member_preferences_path, params: { preferences_form: "1", github_login: "" }

    expect(account.reload.github_login).to be_nil
  end

  it "refuses a name GitHub could not have, and keeps the old one" do
    account.update!(github_login: "mario-rossi")

    patch member_preferences_path, params: { preferences_form: "1", github_login: "mario rossi!" }

    expect(flash[:alert]).to eq(I18n.t("member.preferences.github_invalid"))
    expect(account.reload.github_login).to eq("mario-rossi")
  end
end
