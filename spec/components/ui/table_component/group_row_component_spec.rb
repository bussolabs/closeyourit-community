# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::TableComponent::GroupRowComponent, type: :component do
  it "renders one full-width row with the name, the Mono count and a toggle (C57)" do
    render_inline(described_class.new(key: "closed", label: "Closed", count: 4, colspan: 5, test_id: "group"))
    expect(page).to have_css("tr.ui-table-group[data-test='group'] td[colspan='5']")
    button = page.find("button[data-action='ui--row-group#toggle']")
    expect(button["data-ui--row-group-key-param"]).to eq("closed")
    expect(button["aria-expanded"]).to eq("true")
    expect(button).to have_text("Closed")
    expect(page).to have_css("span.font-mono", text: "4")
  end

  it "names the toggle after the row's test id" do
    render_inline(described_class.new(key: "k", label: "Group", colspan: 2, test_id: "group"))
    expect(page).to have_css("button[data-test='group-toggle']")
  end

  it "takes its own name for the toggle when the group needs one" do
    render_inline(described_class.new(key: "k", label: "Group", colspan: 2, test_id: "group", toggle_test_id: "group-k"))
    expect(page).to have_css("button[data-test='group-k']")
  end

  it "starts closed with a turned chevron when collapsed" do
    render_inline(described_class.new(key: "closed", label: "Closed", colspan: 2, collapsed: true))
    expect(page.find("button")["aria-expanded"]).to eq("false")
    expect(page).to have_css("[data-row-group-chevron].-rotate-90")
  end

  it "marks the count and the group's row as reachable by script (CYRA-1059)" do
    render_inline(described_class.new(key: "closed", label: "Closed", count: "4 rows", colspan: 2))
    expect(page).to have_css("tr.ui-table-group[data-row-group-header='closed'] span[data-row-group-count]", text: "4 rows")
  end

  it "omits the count when none is given" do
    render_inline(described_class.new(key: "k", label: "Group", colspan: 2))
    expect(page).to have_no_css("span.font-mono")
  end

  it "links the group's own page next to the toggle when given an href" do
    render_inline(described_class.new(key: "k", label: "Edge", colspan: 2, href: "/groups/1", link_label: "Open Edge", link_test_id: "group-link"))
    expect(page).to have_css("td > button[aria-expanded]")
    expect(page).to have_css("td > a[href='/groups/1'][aria-label='Open Edge'][data-test='group-link']")
  end

  it "puts the group's own actions at the right end of the row" do
    render_inline(described_class.new(key: "k", label: "Group", colspan: 3)) do |row|
      row.with_actions { "<button type='button' data-test='group-action'>Select</button>".html_safe }
    end
    expect(page).to have_css("tr.ui-table-group td .ml-auto button[data-test='group-action']")
    expect(page).to have_css("button[aria-expanded]")
  end

  it "has no link without an href" do
    render_inline(described_class.new(key: "k", label: "Group", colspan: 2))
    expect(page).to have_no_css("a")
  end
end
