# frozen_string_literal: true

require "rails_helper"

# CYRA-1147 — the browser tab says how much is waiting: "(n)" in front of the title, a dot on the icon.
RSpec.describe "Member tab badge", type: :system, js: true do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: account, organization: org, role: :owner)
    org.update_column(:cto_id, account.id)
  end

  def favicon = page.evaluate_script("document.querySelector(\"link[rel~='icon']\").getAttribute('href')")

  def wait_for_title(pattern)
    wait_until("tab title matching #{pattern.inspect}") { page.title.match?(pattern) }
  end

  def waiting_decisions(count)
    # Bulk fixture in the setup: per-record queries of the factory, not a production N+1.
    allow_n_plus_one do
      count.times do
        create(:ticket, organization: org, project: project, reviewer: account,
                        status: create(:ticket_status, :in_review, organization: org))
      end
    end
  end

  it "counts decisions and unread notifications, once per page, across navigations" do
    waiting_decisions(2)
    create(:alerting_notification, :unread, organization: org, account: account)
    sign_in_as(account)

    visit root_path
    wait_for_title(/\A\(3\) /)
    expect(favicon).to eq("/icon-dot.svg")

    visit member_home_approvals_path
    wait_for_title(/\A\(3\) /)
    expect(page.title).not_to match(/\(3\).*\(3\)/)
  end

  it "counts the decisions on a phone, where the sidebar is closed" do
    waiting_decisions(2)
    sign_in_as(account)
    page.current_window.resize_to(390, 844)

    visit root_path

    wait_for_title(/\A\(2\) /)
  end

  it "keeps the normal title and icon when nothing is waiting" do
    sign_in_as(account)

    visit root_path

    expect(page).to have_css("[data-controller~='tab-badge']")
    expect(page.title).not_to start_with("(")
    expect(favicon).to eq("/icon.svg")
  end

  it "follows a new notification that replaces the bell counter" do
    waiting_decisions(2)
    create(:alerting_notification, :unread, organization: org, account: account)
    sign_in_as(account)
    visit root_path
    wait_for_title(/\A\(3\) /)

    badge = ApplicationController.render(partial: "member/alerting_notifications/badge", locals: { count: 2 })
    stream = %(<turbo-stream action="replace" target="alerting_notification_badge"><template>#{badge}</template></turbo-stream>)
    page.execute_script("Turbo.renderStreamMessage(arguments[0])", stream)

    wait_for_title(/\A\(4\) /)
    expect(favicon).to eq("/icon-dot.svg")
  end
end
