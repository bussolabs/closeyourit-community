# frozen_string_literal: true

require "rails_helper"

# O1 — the page is called Collections: its button, search and messages say collection too,
# never book, which read as a second kind of thing.
RSpec.describe "Collections wording" do
  def strings(node)
    node.is_a?(Hash) ? node.values.flat_map { |value| strings(value) } : [ node.to_s ]
  end

  it "never says book in English" do
    texts = strings(I18n.t("member.knowledge.books", locale: :en))
    expect(texts.grep(/\bbooks?\b/i)).to eq([])
  end

  it "never says libro in Italian" do
    texts = strings(I18n.t("member.knowledge.books", locale: :it))
    expect(texts.grep(/\blibr[oi]\b/i)).to eq([])
  end

  it "explains the empty page without naming a view" do
    %i[en it].each do |locale|
      expect(I18n.t("member.knowledge.books.empty_body", locale: locale)).not_to match(/outline/i)
    end
  end
end
