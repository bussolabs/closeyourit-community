# frozen_string_literal: true

require "rails_helper"

# CYRA-883 — each Knowledge screen says what it holds in its header subtitle, in full, with no help icon.
RSpec.describe "Knowledge area header subtitles", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  {
    "overview" => %i[member_knowledge_root_path member.knowledge.overview.help_title],
    "pages"    => %i[member_knowledge_pages_path member.knowledge.help_title],
    "books"    => %i[member_knowledge_books_path member.knowledge.books.help_title],
    "reviews"  => %i[member_knowledge_reviews_path member.knowledge.reviews.help_title]
  }.each do |name, (page_helper, key)|
    it "the #{name} screen shows its subtitle in full" do
      get public_send(page_helper)

      subtitle = Nokogiri::HTML(response.body).at_css("[data-test$='subtitle']")
      expect(subtitle.text).to eq(I18n.t(key))
    end
  end

  it "the knowledge guide still has the section the books land on" do
    get member_guides_knowledge_path

    expect(response.body).to include('id="books"')
    expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.guides.knowledge.books_title")))
  end
end
