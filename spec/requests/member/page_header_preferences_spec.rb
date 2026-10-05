# frozen_string_literal: true

require "rails_helper"

# DESIGN.md B25: collapsing the page header is the person's choice, saved on the account for every page.
RSpec.describe "Member::PageHeaderPreferences", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before do
    create(:membership, account: account, organization: org, role: :customer)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "saves the collapsed header on the account, whatever the role" do
    patch member_page_header_preference_path, params: { compact: "1" }

    expect(response).to have_http_status(:no_content)
    expect(account.reload.page_header_compact?).to be(true)
  end

  it "saves the expanded header" do
    account.update!(page_header_compact: true)

    patch member_page_header_preference_path, params: { compact: "0" }

    expect(response).to have_http_status(:no_content)
    expect(account.reload.page_header_compact?).to be(false)
  end

  it "renders the header collapsed on the next page once saved" do
    account.update!(page_header_compact: true)

    get member_tickets_path

    header = Nokogiri::HTML(response.body).at_css("header[data-controller~='ui--page-header']")
    expect(header).to be_present
    expect(header["data-pinned"]).to eq("")
    expect(header["data-collapsed"]).to eq("")
  end
end
