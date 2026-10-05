# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::CardComponent, type: :component do
  it "rende body, header e footer" do
    render_inline(described_class.new) do |card|
      card.with_header { "Titolo" }
      card.with_footer { "Footer" }
      "Corpo"
    end
    expect(page).to have_css("div.rounded-lg.border.bg-white", text: "Corpo")
    expect(page).to have_text("Titolo")
    expect(page).to have_text("Footer")
  end

  it "usa il bordo indigo quando highlighted" do
    render_inline(described_class.new(highlighted: true)) { "x" }
    expect(page).to have_css("div.border-indigo-600")
  end

  it "usa il bordo stone di default" do
    render_inline(described_class.new) { "x" }
    expect(page).to have_css("div.border-stone-200")
  end
end
