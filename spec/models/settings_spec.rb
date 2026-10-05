# frozen_string_literal: true

require "rails_helper"

RSpec.describe Settings do
  it "table_name_prefix namespacea le tabelle del modulo (settings_)" do
    expect(described_class.table_name_prefix).to eq("settings_")
  end
end
