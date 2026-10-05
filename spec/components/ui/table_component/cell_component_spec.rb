# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::TableComponent::CellComponent, type: :component do
  it "renders a data cell with the shared padding class" do
    render_inline(described_class.new) { "value" }
    expect(page).to have_css("td.ui-table-cell", text: "value")
  end

  # C69, C73 — the card below 768px reads the column name from the cell itself.
  it "carries the column label for the mobile card" do
    render_inline(described_class.new(label: "Production")) { "value" }
    expect(page).to have_css("td.ui-table-cell[data-label='Production']")
  end

  it "renders the row's name cell as a row header" do
    render_inline(described_class.new(header: true)) { "API_KEY" }
    expect(page).to have_css("th.ui-table-cell.ui-table-cell--title[scope='row']", text: "API_KEY")
  end

  it "aligns numbers right in Mono" do
    render_inline(described_class.new(align: :right, mono: true)) { "42" }
    expect(page).to have_css("td.ui-table-cell.text-right.font-mono", text: "42")
  end

  it "marks the actions cell so the card keeps the buttons together" do
    render_inline(described_class.new(actions: true)) { "<button>Edit</button>".html_safe }
    expect(page).to have_css("td.ui-table-cell.ui-table-cell--actions.text-right button", text: "Edit")
  end

  # C76 — a column that says nothing in this view is hidden by the component.
  it "renders nothing when the column is hidden" do
    render_inline(described_class.new(visible: false)) { "value" }
    expect(page).to have_no_css("td")
  end

  it "keeps the caller's attributes" do
    render_inline(described_class.new(test_id: "cell", data: { x: "1" }, class: "align-top")) { "v" }
    expect(page).to have_css("td.ui-table-cell.align-top[data-test='cell'][data-x='1']")
  end
end
