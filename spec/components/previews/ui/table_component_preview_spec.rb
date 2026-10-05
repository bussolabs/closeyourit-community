# frozen_string_literal: true

require "rails_helper"

# CYRA-924 — every table preview renders: a preview that raises is seen by nobody until that page opens.
RSpec.describe Ui::TableComponentPreview, type: :component do
  let(:described_class) { Ui::TableComponent }

  described_class_preview = Ui::TableComponentPreview
  (described_class_preview.examples - [ "states" ]).each do |example|
    it "renders the '#{example}' example" do
      expect { render_preview(example, from: described_class_preview) }.not_to raise_error
    end
  end

  %w[empty no_results loading error].each do |kind|
    it "renders the '#{kind}' state" do
      render_preview(:states, from: described_class_preview, params: { kind: kind })
      expect(page).to have_css("tr.ui-table-state [data-table-state='#{kind}']")
    end
  end

  it "renders the matrix with a sticky name column and a pulsing Missing pill" do
    render_preview(:matrix, from: described_class_preview)
    expect(page).to have_css("table.ui-table--stacked.ui-table--sticky-first")
    expect(page).to have_css("td.ui-table-cell", text: "Missing")
    expect(page).to have_no_css("[class*='ui-table-cell--missing']")
    expect(page).to have_css("tr[aria-current='true']")
  end

  it "starts the closed group collapsed" do
    render_preview(:grouped, from: described_class_preview)
    expect(page).to have_css("tr.ui-table-row[data-row-group-key='Closed'][hidden]", visible: :all)
    expect(page).to have_css("tr.ui-table-row[data-row-group-key='Public APIs']:not([hidden])")
  end
end
