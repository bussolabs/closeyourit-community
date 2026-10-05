# frozen_string_literal: true

require "rails_helper"

# DESIGN.md T13 — information secondary to a page sits side by side in columns, never stacked full
# width one panel after the other.
RSpec.describe "Secondary panels in columns (T13)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def secondary_tests(path)
    get path
    expect(response).to have_http_status(:ok)
    grid = Nokogiri::HTML(response.body).at_css("[data-test='secondary-panels']")
    expect(grid).to be_present
    expect(grid["class"]).to include("lg:grid-cols-2")
    grid.css("> *").map { |panel| panel["data-test"] }
  end

  it "puts the fleet token notes side by side" do
    expect(secondary_tests(member_monitoring_server_tokens_path))
      .to eq(%w[server-tokens-compromised server-tokens-status])
  end

  it "puts what reaches you on Telegram and the bot commands side by side" do
    expect(secondary_tests(member_telegram_connection_path)).to eq(%w[telegram-what telegram-commands])
  end

  it "puts the vault capabilities in two columns" do
    expect(secondary_tests(member_vault_capabilities_path).size).to eq(7)
  end
end
