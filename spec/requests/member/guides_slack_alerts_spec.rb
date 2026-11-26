# frozen_string_literal: true

require "rails_helper"

# CYRA-1156 — the guide of the Slack app channel: what it does, the app permissions, the buttons.
RSpec.describe "Member::Guides Slack alerts", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before do
    create(:membership, account: account, organization: org, role: :member)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "explains the channel, the app permissions, linking people and the buttons" do
    get member_guides_slack_alerts_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="member-guide-slack-alerts"')
    %w[what app channel people buttons].each do |section|
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.guides.slack_alerts.#{section}_title")))
    end
    text = Nokogiri::HTML(response.body).text
    expect(text).to include("chat:write", "/slack/interactions")
  end

  it "is reached from the delivery channels page" do
    expect(Guides::Map.path_for("/member/alerting/channels")).to eq(member_guides_slack_alerts_path)
  end
end
