# frozen_string_literal: true

require "rails_helper"

# The hourly rollup and the raw prune filter raw checks by time across all monitors: without an
# index led by checked_at every run reads the whole table (CYRA-892).
RSpec.describe "Raw uptime checks index", type: :model do
  it "indexes raw checks by checked_at" do
    index = ActiveRecord::Base.connection.indexes("uptime_checks").find { |i| i.columns == [ "checked_at" ] }

    expect(index).to be_present
    expect(index.where).to match(/granularity = 0/)
  end
end
