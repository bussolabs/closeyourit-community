# frozen_string_literal: true

require "rails_helper"

# The ticket side column scrolls on its own. A select panel left inside that column was cut by it, or
# stretched its scroll box. The panel must leave the flow and stay whole on screen.
RSpec.describe "Ui::Select — the panel is not cut by a scrolling column", :js, type: :system do
  let(:org) { create(:organization) }
  let(:owner) { create(:account, locale: "it") }
  let(:project) { create(:project, organization: org) }
  let!(:ticket) { create(:ticket, project: project) }

  before do
    css = Rails.root.join("app/assets/builds/tailwind.css")
    skip "Tailwind CSS not built (bin/rails tailwindcss:build)" unless css.exist? && css.size.positive?

    create(:membership, account: owner, organization: org, role: :owner)
    create_list(:ticket, 7, project: project)
    sign_in_as(owner)
  end

  def panel_geometry
    page.evaluate_script(<<~JS)
      (() => {
        const select = document.querySelector("select[data-test='dependency-blocker-select']");
        const panel = select.parentElement.querySelector("[role='listbox']").closest("div.absolute, div[style*='fixed']");
        const r = panel.getBoundingClientRect();
        const rows = panel.querySelectorAll("[role='option']");
        const last = rows[rows.length - 1].getBoundingClientRect();
        const hit = document.elementFromPoint(last.left + 4, Math.min(last.top + 4, r.bottom - 4));
        return { top: r.top, bottom: r.bottom, vh: window.innerHeight, topmost: panel.contains(hit) };
      })()
    JS
  end

  it "opens the dependency picker whole on screen, above everything around it" do
    page.driver.browser.manage.window.resize_to(1400, 760)
    visit member_ticket_path(ticket)

    trigger = find("select[data-test='dependency-blocker-select']", visible: :all)
              .find(:xpath, "..").find("button[aria-haspopup='listbox']")
    trigger.scroll_to(trigger, align: :center)
    trigger.click
    expect(page).to have_css("[role='combobox']", visible: true)

    g = panel_geometry
    expect(g["top"]).to be >= 0
    expect(g["bottom"]).to be <= g["vh"]
    expect(g["topmost"]).to be(true), "something covers the panel: it is cut by its column"
  end
end
