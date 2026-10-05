# frozen_string_literal: true

require "rails_helper"

# CYRA-910 — the one-line empty inside a panel ("no comments yet") has a single look everywhere.
RSpec.describe Ui::EmptyNoteComponent, type: :component do
  it "renders the text with the shared muted style and the test id" do
    page = render_inline(described_class.new(text: "No comments yet", test_id: "note"))
    note = page.css("[data-test='note']").first

    expect(note.text).to include("No comments yet")
    expect(note[:class]).to include("text-[12.5px]", "text-gray-500")
    expect(note[:class]).not_to include("px-4")
  end

  it "inset adds the padding of a list row, for panels whose body has none" do
    note = render_inline(described_class.new(text: "Empty", inset: true, test_id: "note")).css("[data-test='note']").first

    expect(note[:class]).to include("px-4", "py-6")
  end

  it "shows the hint only when given" do
    expect(render_inline(described_class.new(text: "Empty")).css("[data-test='empty-note-hint']")).to be_empty

    page = render_inline(described_class.new(text: "Empty", hint: "Run the analysis to fill it."))
    expect(page.css("[data-test='empty-note-hint']").text).to include("Run the analysis")
  end
end
