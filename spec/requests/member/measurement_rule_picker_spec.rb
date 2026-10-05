# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Legacy alert rule picker", type: :request do
  it "does not offer new measurement rules before the dedicated form is available" do
    account = create(:account)
    organization = create(:organization)
    create(:membership, account: account, organization: organization, role: :owner)
    post login_path, params: { email: account.email, password: "Secret123!" }
    get new_member_alerting_rule_path
    expect(response).to have_http_status(:ok)
    picker = Nokogiri::HTML(response.body).at_css("select#event_type")
    expect(picker.css("option").map { |option| option["value"] }).not_to include("measurement_threshold")
    expect(picker.css("option").map { |option| option["value"] }).to include("metric_threshold")
  end
end
