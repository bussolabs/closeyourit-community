# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::TableComponent::RowComponent, type: :component do
  def render_row(**opts)
    render_inline(described_class.new(**opts)) { "<td>cell</td>".html_safe }
  end

  it "renders a plain row with the shared row class and its cells" do
    render_row(test_id: "row")
    expect(page).to have_css("tr.ui-table-row[data-test='row'] td", text: "cell")
    expect(page).to have_no_css("tr[data-controller]")
  end

  # C55 — the whole row opens the detail, with a real link at the end for keyboard and new tabs.
  context "with href" do
    it "opens the detail from the whole row and ends with a chevron link" do
      render_row(href: "/member/x", link_label: "Open x")
      row = page.find("tr.ui-table-row")
      expect(row["data-controller"]).to include("ui--row-link")
      expect(row["data-action"]).to include("click->ui--row-link#open")
      expect(row["data-ui--row-link-url-value"]).to eq("/member/x")
      expect(page).to have_css("tr td.ui-table-chevron a[href='/member/x'][aria-label='Open x']")
    end
  end

  it "marks a highlighted row as current (C70)" do
    render_row(highlighted: true)
    expect(page).to have_css("tr.ui-table-row[aria-current='true']")
  end

  it "marks a selected row (C74)" do
    render_row(selected: true)
    expect(page).to have_css("tr.ui-table-row[aria-selected='true']")
  end

  it "fades a suspended or zero row without hiding it (C79)" do
    render_row(faded: true)
    expect(page).to have_css("tr.ui-table-row.ui-table-row--faded")
  end

  it "joins a collapsible group and starts hidden when the group is closed (C57)" do
    render_row(group: "inactive", hidden: true)
    row = page.find("tr.ui-table-row", visible: :all)
    expect(row["data-ui--row-group-target"]).to eq("row")
    expect(row["data-row-group-key"]).to eq("inactive")
    expect(row[:hidden]).not_to be_nil
  end

  it "keeps the caller's id, classes and data" do
    render_row(id: "secret-x", class: "scroll-mt-24", data: { controller: "secret-row" })
    expect(page).to have_css("tr#secret-x.ui-table-row.scroll-mt-24[data-controller='secret-row']")
  end

  it "adds the row link controller next to the caller's own controller" do
    render_row(href: "/x", link_label: "Open", data: { controller: "other" })
    expect(page.find("tr")["data-controller"].split).to contain_exactly("other", "ui--row-link")
  end

  # C56 — the row's own selection box, first in the row.
  describe "select" do
    it "renders a checkbox cell first, wired to the bulk selection" do
      render_row(select: { value: "42", name: "ids[]", label: "Select 42", test_id: "error-select-42" })
      box = page.find("tr > td.ui-table-select:first-child input[type='checkbox']")
      expect(box[:name]).to eq("ids[]")
      expect(box[:value]).to eq("42")
      expect(box["aria-label"]).to eq("Select 42")
      expect(box["data-test"]).to eq("error-select-42")
      expect(box["data-ui--bulk-select-target"]).to eq("checkbox")
      expect(box["data-action"]).to eq("change->ui--bulk-select#update")
    end

    it "merges extra data on the checkbox" do
      render_row(select: { value: "k", data: { no_report: true } })
      expect(page.find("input[type='checkbox']")["data-no-report"]).to eq("true")
    end

    it "keeps an empty first cell for a row that cannot be selected" do
      render_row(select: :none)
      expect(page).to have_css("tr > td.ui-table-select:first-child", text: "")
      expect(page).to have_no_css("input[type='checkbox']")
    end

    it "renders no selection cell without select" do
      render_row
      expect(page).to have_no_css("td.ui-table-select")
    end
  end

  # A row inside a Turbo frame opens its detail on the whole page.
  it "sends the chevron link to the given frame" do
    render_row(href: "/x", link_label: "Open", frame: "_top")
    expect(page.find("td.ui-table-chevron a")["data-turbo-frame"]).to eq("_top")
  end
end
