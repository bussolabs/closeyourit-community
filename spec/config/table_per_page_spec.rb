# frozen_string_literal: true

require "rails_helper"

# DESIGN.md C11 and knowledge base data-tables.md: every list shows 12 rows per page by default,
# and 12 is the first choice of the rows-per-page picker.
RSpec.describe "Rows per page" do
  it "defaults every list to 12 rows" do
    expect(App::Constants::TABLE_PER_PAGE).to eq(12)
  end

  it "offers 12 as the first rows-per-page choice" do
    expect(Pagination::PER_OPTIONS).to eq([ 12, 25, 50, 100 ])
  end
end
