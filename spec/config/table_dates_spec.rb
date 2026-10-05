# frozen_string_literal: true

require "rails_helper"

# CYRA-924 — M10: a date in a table goes through the locale (`l(...)`), never `strftime`, which
# prints the Italian order in every language.
RSpec.describe "Table views format dates through the locale" do
  it "has no strftime in a view that renders table rows or cells" do
    offenders = Dir[Rails.root.join("app/views/**/*.erb")].filter_map do |path|
      source = File.read(path)
      next unless source.match?(/Ui::TableComponent::(RowComponent|CellComponent)/)

      source.each_line.with_index(1).filter_map { |line, number| "#{path.delete_prefix("#{Rails.root}/")}:#{number}" if line.include?(".strftime(") }
    end.flatten

    expect(offenders).to be_empty, "Dates through l(...), not strftime: #{offenders.join(', ')}"
  end
end
