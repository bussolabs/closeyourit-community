# frozen_string_literal: true

require "rails_helper"

# C58 — the detail under a row: one cell across every column, hidden until opened.
RSpec.describe Ui::TableComponent::DetailRowComponent, type: :component do
  it "renders one full-width cell with the content" do
    render_inline(described_class.new(colspan: 4, test_id: "detail")) { "Invitation link" }
    expect(page).to have_css("tr.ui-table-detail[data-test='detail'] td[colspan='4']", text: "Invitation link")
  end

  it "starts hidden when asked" do
    render_inline(described_class.new(colspan: 2, hidden: true)) { "x" }
    expect(page.find("tr.ui-table-detail", visible: :all)[:hidden]).not_to be_nil
  end

  it "keeps the caller's id, classes and data" do
    render_inline(described_class.new(colspan: 2, id: "d1", class: "extra", data: { group: "a" })) { "x" }
    expect(page).to have_css("tr#d1.ui-table-detail.extra[data-group='a']")
  end
end
