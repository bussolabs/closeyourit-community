# frozen_string_literal: true

require "rails_helper"

RSpec.describe Member::ScopeNamesHelper, type: :helper do
  it "writes a short list in full" do
    expect(helper.scope_names_summary(%w[Billing Auth])).to eq("Billing · Auth")
  end

  it "shows the first three and +N, keeping every name on hover and for screen readers" do
    html = Capybara.string(helper.scope_names_summary(%w[Billing Auth Shipping Inventory Search]))

    summary = html.find("[data-test='scope-names-summary']")
    expect(summary[:title]).to eq("Billing · Auth · Shipping · Inventory · Search")
    expect(summary).to have_css("span[aria-hidden='true']", text: "+2")
    expect(summary.find(".sr-only").text).to include("Inventory", "Search")
  end

  it "escapes the names" do
    expect(helper.scope_names_summary([ "<b>x</b>" ])).to eq("&lt;b&gt;x&lt;/b&gt;")
  end
end
