# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::DetailsComponent, type: :component do
  it "renders a titled panel with one label/value row per fact" do
    render_inline(described_class.new(title: "Details", test_id: "project-about")) do |details|
      details.with_row(label: "Group", value: "Platform", test_id: "project-group")
    end

    expect(page).to have_css("[data-test='project-about']", text: "Details")
    expect(page).to have_css("[data-test='project-group']", text: "Group")
    expect(page).to have_css("[data-test='project-group']", text: "Platform")
  end

  it "puts the label above the value on phones and the value on the right from sm" do
    render_inline(described_class.new(title: "Details")) { |details| details.with_row(label: "Group", value: "Platform") }

    expect(page).to have_css("div.grid.grid-cols-1.sm\\:flex.sm\\:justify-between")
    expect(page).to have_css("div.min-w-0.sm\\:justify-end", text: "Platform")
  end

  it "accepts a composed value instead of a string" do
    render_inline(described_class.new(title: "Details")) do |details|
      details.with_row(label: "Repository") { "<a href='/repo'>owner/repo</a>".html_safe }
    end

    expect(page).to have_css("a[href='/repo']", text: "owner/repo")
  end

  it "hides a row with nothing to say (E7)" do
    render_inline(described_class.new(title: "Details")) do |details|
      details.with_row(label: "Group", value: nil, test_id: "project-group")
      details.with_row(label: "Kind", value: "Web")
    end

    expect(page).to have_no_css("[data-test='project-group']")
    expect(page).to have_no_text("—")
    expect(page).to have_text("Kind")
  end

  it "does not render the panel when every row is empty (E7)" do
    render_inline(described_class.new(title: "Details")) { |details| details.with_row(label: "Group", value: nil) }

    expect(rendered_content).to be_empty
  end

  it "places the row action next to its label" do
    render_inline(described_class.new(title: "Details")) do |details|
      details.with_row(label: "Environments", value: "production", action: "<a href='/tokens'>Manage tokens</a>".html_safe)
    end

    expect(page).to have_css("span", text: "Environments") { |label| label.has_css?("a[href='/tokens']") }
  end

  it "closes the panel with the footer under every row (E22)" do
    render_inline(described_class.new(title: "Details")) do |details|
      details.with_row(label: "Group", value: "Platform")
      details.with_footer { "Created by Alessio" }
    end

    expect(page).to have_css("div.border-t", text: "Created by Alessio")
  end
end
