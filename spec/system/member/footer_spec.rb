# frozen_string_literal: true

require "rails_helper"

# The member footer's buttons: support with the requests still open, and the version with its signal.
RSpec.describe "Member footer", :js, type: :system do
  let(:org) { create(:organization, name: "Demo Org") }
  let(:owner) { create(:account, name: "Olivia") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Support::Request.create!(account: owner, organization: org, body: "Still open")
    sign_in_as(owner)
    visit member_projects_path
  end

  it "drops the version signal on the first click and keeps it off after a reload" do
    expect(page).to have_css("[data-test='footer-version'] [data-test='footer-version-new']")
    page.save_screenshot(Rails.root.join("tmp/footer.png").to_s) if ENV["FOOTER_SHOT"]

    click_on_test "footer-version"

    expect(page).to have_css("dialog[data-test='changelog-modal'][open]")
    expect(page).to have_no_css("[data-test='footer-version-new']")
    wait_until("release saved as seen") { owner.reload.notice_dismissed?("release:#{Changelog.current.label}") }

    visit member_projects_path
    expect(page).to have_css("[data-test='footer-version']")
    expect(page).to have_no_css("[data-test='footer-version-new']")
  end

  it "opens the person's support requests from the open count" do
    click_on_test "footer-support-open"

    expect(page).to have_current_path(member_support_requests_path)
    expect(page).to have_text("Still open")
  end

  it "opens the language menu upwards and switches language from it" do
    find("[data-test='footer-locale']").click

    expect(page).to have_css("[data-test='footer-locale-it']", visible: :visible)
    page.save_screenshot(Rails.root.join("tmp/footer_locale.png").to_s) if ENV["FOOTER_SHOT"]
    above = page.evaluate_script(<<~JS)
      document.querySelector("[data-test='footer-locale-it']").getBoundingClientRect().bottom <=
        document.querySelector("[data-test='footer-locale']").getBoundingClientRect().top
    JS
    expect(above).to be(true)

    click_on_test "footer-locale-it"

    expect(page).to have_css("[data-test='footer-locale']", text: "Italiano")
    expect(owner.reload.locale).to eq("it")
  end

  it "blurs the page behind an open dialog" do
    click_on_test "footer-version"

    expect(page).to have_css("dialog[data-test='changelog-modal'][open]")
    blur = page.evaluate_script(
      "getComputedStyle(document.querySelector(\"dialog[data-test='changelog-modal']\"), '::backdrop').backdropFilter"
    )
    expect(blur).to include("blur")
  end

  it "ends a guide with one line, not two: the last panel leaves the bottom line to the frame" do
    visit member_guides_uptime_path

    expect(page).to have_css("[data-test='member-guide-uptime'] [data-flush~='bottom']")
    width = page.evaluate_script(
      "getComputedStyle([...document.querySelectorAll(\"[data-test='member-guide-uptime'] [data-flush~='bottom']\")].pop()).borderBottomWidth"
    )
    expect(width).to eq("0px")
  end
end
