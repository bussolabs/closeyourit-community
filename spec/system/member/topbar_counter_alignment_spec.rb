# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Topbar counters alignment", type: :system, js: true do
  it "keeps every counter on the same line as its icon" do
    org = create(:organization)
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    create(:alerting_notification, :unread, organization: org, account: account)
    create(:alerting_notification, :unread, organization: org, account: account, event_type: :chat_message)
    list = create(:todo_list, organization: org, account: account)
    create(:todo_item, list: list, done: false)
    create(:todo_item, list: list, done: true, completed_at: Time.current)
    sign_in_as(account)
    page.current_window.resize_to(1440, 900)

    visit root_path

    expect(page).to have_css("[data-test='member-nav-todos-badge']", text: "1")
    gaps = page.evaluate_script(<<~JS)
      (() => {
        const mid = (el) => { const r = el.getBoundingClientRect(); return r.top + r.height / 2; };
        const pairs = [
          ["[data-test='notification-bell']", "[data-test='notification-badge'] span"],
          ["[data-test='member-nav-chat']", "[data-test='member-nav-chat-badge']"],
          ["[data-test='member-nav-todos']", "[data-test='member-nav-todos-badge']"]
        ];
        return pairs.map(([box, badge]) => {
          const el = document.querySelector(box);
          return Math.abs(mid(el.querySelector("svg")) - mid(el.querySelector(badge)));
        });
      })()
    JS

    expect(gaps).to all(be <= 1)
  end
end
