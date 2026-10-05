# frozen_string_literal: true

require "rails_helper"

# CYRA-935 — the Support button slides the page up; the message survives going back to the page.
RSpec.describe "Member — Support", :js, type: :system do
  let(:org) { create(:organization, name: "Acme") }
  let(:account) { create(:account) }

  before do
    create(:membership, account:, organization: org, role: :member)
    sign_in_as(account)
    visit member_todo_lists_path
  end

  it "slides the page away, shows what goes with the message and sends it" do
    click_on_test "footer-support"

    expect(page).to have_css("[data-test='support-screen']", visible: :visible)
    expect(page).to have_no_css("[data-test='member-footer']", visible: :visible)
    expect(find("[data-test='support-context-page']")).to have_text("/member/lists")
    # T1 — the panels touch the frame: only the corners on those sides are square.
    expect(page).to have_css("[data-test='support-context'][data-flush~='left']")
    expect(page).to have_css("[data-test='support-header'][data-flush~='top'][data-flush~='left'][data-flush~='right']")
    expect(find("[data-test='support-context-window']").text).to match(/\d+ × \d+/)

    fill_test "support-body", with: "The board loses the column order."
    click_on_test "support-send"

    expect(page).to have_css("[data-test='support-sent']")
    saved = Support::Request.last
    expect(saved.body).to eq("The board loses the column order.")
    expect(saved.context).to include("page" => "/member/lists", "page_title" => a_string_including("CloseYourIt"))
    page.save_screenshot(Rails.root.join("tmp/support_sent.png")) if ENV["SHOTS"]
  end

  it "keeps the text when the person goes back to the page and opens Support again" do
    click_on_test "footer-support"
    fill_test "support-body", with: "Half a sentence"
    expect(page).to have_no_css("[data-test='member-footer']", visible: :visible)
    page.save_screenshot(Rails.root.join("tmp/support_open.png")) if ENV["SHOTS"]
    click_on_test "support-back"

    expect(page).to have_css("[data-test='member-footer']", visible: :visible)
    expect(page).to have_no_css("[data-test='support-screen']", visible: :visible)

    visit member_todo_lists_path
    click_on_test "footer-support"

    expect(find("[data-test='support-body']").value).to eq("Half a sentence")
  end
end
