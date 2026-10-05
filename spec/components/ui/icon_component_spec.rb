# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::IconComponent, type: :component do
  # DESIGN.md A31 — every icon is a Lucide outline glyph drawn by this component (CYRA-926).
  it "draws the named Lucide icon as an outline SVG" do
    render_inline(described_class.new(name: "ticket"))

    svg = page.find("svg[data-icon='ticket']", visible: :all)
    expect(svg[:fill]).to eq("none")
    expect(svg[:stroke]).to eq("currentColor")
  end

  it "sizes itself from the surrounding font size, like the glyph it replaces" do
    render_inline(described_class.new(name: "ticket", class: "text-[11px] text-gray-400"))

    svg = page.find("svg", visible: :all)
    expect(svg[:width]).to eq("1em")
    expect(svg[:height]).to eq("1em")
    expect(svg[:class]).to include("text-[11px]", "text-gray-400", "inline-block", "shrink-0")
  end

  it "is hidden from screen readers when it has no label" do
    render_inline(described_class.new(name: "ticket"))

    svg = page.find("svg", visible: :all)
    expect(svg[:"aria-hidden"]).to eq("true")
    expect(svg[:role]).to be_nil
  end

  it "is announced as an image when it carries a label" do
    render_inline(described_class.new(name: "triangle-alert", label: "Warning"))

    svg = page.find("svg", visible: :all)
    expect(svg[:role]).to eq("img")
    expect(svg[:"aria-label"]).to eq("Warning")
    expect(svg[:"aria-hidden"]).to be_nil
  end

  it "shows its label as a tooltip, which an SVG only does through a title element" do
    render_inline(described_class.new(name: "info", label: "Recently active ideas first"))

    expect(page.find("svg > title", visible: :all).text(:all)).to eq("Recently active ideas first")
  end

  it "keeps the caller's data attributes and test id" do
    render_inline(described_class.new(name: "copy", test_id: "copy-token", data: { action: "click->clipboard#copy" }))

    svg = page.find("svg[data-test='copy-token']", visible: :all)
    expect(svg[:"data-action"]).to eq("click->clipboard#copy")
    expect(svg[:"data-icon"]).to eq("copy")
  end

  it "refuses a name Lucide does not have, such as a Font Awesome one" do
    expect { render_inline(described_class.new(name: "magnifying-glass")) }.to raise_error(ArgumentError, /magnifying-glass/)
  end
end
