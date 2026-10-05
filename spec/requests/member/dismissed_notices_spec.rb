# frozen_string_literal: true

require "rails_helper"

# A floating notice, once dismissed, stays dismissed on every device: the choice is on the account.
RSpec.describe "Member::DismissedNotices", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before do
    create(:membership, account: account, organization: org, role: :customer)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "saves a known notice as dismissed, whatever the role" do
    post member_dismissed_notices_path, params: { key: "alerting_hierarchy" }

    expect(response).to have_http_status(:no_content)
    expect(account.reload.notice_dismissed?("alerting_hierarchy")).to be(true)
  end

  it "keeps the list free of duplicates" do
    account.update!(dismissed_notices: [ "alerting_hierarchy" ])

    post member_dismissed_notices_path, params: { key: "alerting_hierarchy" }

    expect(account.reload.dismissed_notices).to eq([ "alerting_hierarchy" ])
  end

  it "saves the steps of one project as dismissed" do
    key = "project_next_steps:#{SecureRandom.uuid}:error-to-ticket,setup-token"

    post member_dismissed_notices_path, params: { key: }

    expect(response).to have_http_status(:no_content)
    expect(account.reload.notice_dismissed?(key)).to be(true)
  end

  it "saves a release as seen and forgets the older ones" do
    account.update!(dismissed_notices: [ "release:v0.1.0", "alerting_hierarchy" ])

    post member_dismissed_notices_path, params: { key: "release:v0.2.0" }

    expect(response).to have_http_status(:no_content)
    expect(account.reload.dismissed_notices).to contain_exactly("alerting_hierarchy", "release:v0.2.0")
  end

  it "refuses a key that names no notice" do
    post member_dismissed_notices_path, params: { key: "anything" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(account.reload.dismissed_notices).to be_empty
  end
end
