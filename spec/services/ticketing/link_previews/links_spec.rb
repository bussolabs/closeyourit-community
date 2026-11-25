# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::LinkPreviews::Links do
  it "finds bare and markdown links, in order and without repeats" do
    text = "See https://www.figma.com/file/abc/Design. Also [docs](https://docs.test/page) " \
           "and https://www.figma.com/file/abc/Design again."

    expect(described_class.from(text)).to eq([ "https://www.figma.com/file/abc/Design", "https://docs.test/page" ])
  end

  it "keeps at most five links" do
    text = (1..8).map { |n| "https://site#{n}.test/" }.join(" ")

    expect(described_class.from(text).size).to eq(described_class::MAX)
  end

  it "ignores schemes other than http and https" do
    expect(described_class.from("ftp://files.test/a file:///etc/passwd javascript:alert(1)")).to eq([])
  end

  it "returns nothing for an empty description" do
    expect(described_class.from(nil)).to eq([])
  end
end
