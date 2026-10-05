# frozen_string_literal: true

require "rails_helper"

# The assistant guide: what you can ask, what it prepares for you to confirm, and what it never does.
RSpec.describe "Member — assistant guide", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before do
    create(:membership, account:, organization: org, role: :member)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "explains questions, confirmed actions and limits, each with examples" do
    get member_guides_assistant_path

    expect(response).to have_http_status(:ok)
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("[data-test='member-guide-assistant']")).to be_present
    expect(doc.css("[data-test='guide-assistant-section']").size).to eq(4)
    expect(doc.css("[data-test='guide-assistant-example']").size).to be >= 12
  end
end
