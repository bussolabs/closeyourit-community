# frozen_string_literal: true

require "rails_helper"

# The General tab is one panel: a row per preference and a single Save for all of them.
RSpec.describe "Member preferences as a single list", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before do
    create(:membership, account: account, organization: org, role: :member)
    create(:platform, organization: org, code: "web", label: "Web")
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def doc = Nokogiri::HTML(response.body)

  it "renders every preference as a row of one form with one Save" do
    get member_preferences_path

    expect(doc.css("form[data-test='preferences-list']").size).to eq(1)
    rows = doc.css("[data-test='preferences-list'] [data-test^='preferences-row-']").map { it["data-test"] }
    expect(rows).to eq(%w[preferences-row-platforms preferences-row-language preferences-row-theme preferences-row-display])
    expect(doc.css("[data-test='preferences-submit']").size).to eq(1)
    expect(doc.css("[data-test$='-submit'][data-test^='preferences-']").size).to eq(1)
  end

  it "saves all the preferences at once and comes back with a notice" do
    patch member_preferences_path, params: {
      preferences_form: "1", platform_codes: [ "", "web" ], locale: "it", theme: "dark", projects_view: "table"
    }

    account.reload
    expect([ account.platform_codes, account.locale, account.theme, account.projects_view ])
      .to eq([ [ "web" ], "it", "dark", "table" ])
    expect(response).to redirect_to(member_preferences_path)
    expect(flash[:notice]).to be_present
  end
end
