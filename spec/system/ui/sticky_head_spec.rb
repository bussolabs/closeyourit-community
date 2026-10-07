# frozen_string_literal: true

require "rails_helper"

# C42 — the header row of a table stays under the page header while the page scrolls. A table inside an
# inner scrolling column must not get the page header's height: its header was pushed over its own rows
# and swallowed the clicks meant for them.
RSpec.describe "Ui::Table — header kept in view", type: :system, js: true do
  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
    sign_in_as(owner)
  end

  def geometry
    page.evaluate_script(<<~JS)
      (() => {
        const table = document.querySelector("table[data-controller~='ui--sticky-head']");
        const main = document.getElementById("main-content");
        const shift = parseFloat(table.style.getPropertyValue("--ui-head-shift")) || 0;
        return { shift, tableTop: table.getBoundingClientRect().top,
                 line: main.getBoundingClientRect().top + (parseFloat(main.style.getPropertyValue("--page-header-h")) || 0) };
      })()
    JS
  end

  it "keeps the header under the page header once the table top has scrolled past it" do
    create_list(:error_group, 12, project:)
    page.current_window.resize_to(1280, 520)
    visit member_monitoring_error_groups_path
    expect(page).to have_css("table[data-controller~='ui--sticky-head'] tbody tr", minimum: 12, wait: 8)

    page.execute_script("document.getElementById('main-content').scrollTop = 400")

    expect(page).to have_css("table[data-head-shifted]", wait: 4)
    expect(geometry["shift"]).to be_within(2).of(geometry["line"] - geometry["tableTop"])
  end

  it "keeps the sticky corner above the other shifted header cells" do
    create_list(:error_group, 2, project:)
    visit member_monitoring_error_groups_path
    expect(page).to have_css("table[data-controller~='ui--sticky-head'] thead th", minimum: 2, wait: 8)

    layers = page.evaluate_script(<<~JS)
      (() => {
        const table = document.querySelector("table[data-controller~='ui--sticky-head']");
        table.classList.add("ui-table--sticky-first");
        table.setAttribute("data-head-shifted", "");
        const [corner, next] = table.tHead.rows[0].cells;
        return [ getComputedStyle(corner).zIndex, getComputedStyle(next).zIndex ].map(Number);
      })()
    JS

    expect(layers.first).to be > layers.last
  end

  it "leaves the header alone in a table that sits low inside its own scrolling column" do
    group = create(:error_group, project:, title: "RuntimeError: boom")
    create(:error_event, group:, project:, occurred_at: 1.minute.ago)
    create(:error_event, group:, project:, occurred_at: 10.minutes.ago)
    visit member_monitoring_error_group_path(group)
    expect(page).to have_css("[data-test='occurrence-row']", count: 2, wait: 8)

    page.all("[data-test='occurrence-row']").last.click

    expect(page).to have_no_css("table[data-head-shifted]")
  end
end
