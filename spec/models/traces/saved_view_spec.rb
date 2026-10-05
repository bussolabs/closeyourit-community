# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Saved trace filters" do
  it "preserves canonical empty environment and exact resource strings" do
    view = build(:saved_view, resource_type: "traces", filters: { "environment" => "", "service" => " checkout ", "version" => " ", "sort" => "-duration" })
    expect(view).to be_valid
    expect(view.filters).to include("environment" => "", "service" => " checkout ", "version" => " ")
  end
end
