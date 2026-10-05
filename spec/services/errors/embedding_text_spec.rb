# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::EmbeddingText do
  it "compone title e culprit" do
    group = build(:error_group, title: "RuntimeError: boom", culprit: "App::Widget#render")

    expect(described_class.call(group: group)).to eq("RuntimeError: boom\nApp::Widget#render")
  end

  it "salta il culprit vuoto" do
    group = build(:error_group, title: "RuntimeError: boom", culprit: nil)

    expect(described_class.call(group: group)).to eq("RuntimeError: boom")
  end

  it "checksum stabile a parità di contenuto, diverso al cambio di title" do
    group = build(:error_group, title: "A", culprit: "B")
    first = described_class.checksum(group: group)

    expect(described_class.checksum(group: group)).to eq(first)

    group.title = "C"
    expect(described_class.checksum(group: group)).not_to eq(first)
  end
end
