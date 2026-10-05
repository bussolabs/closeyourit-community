# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::Page, type: :model do
  it "factory valida" do
    expect(build(:seo_page)).to be_valid
  end

  it "una URL esiste una volta sola per sito" do
    page = create(:seo_page)
    expect(build(:seo_page, site: page.site, url: page.url)).not_to be_valid
    # Lo stesso indirizzo su un altro sito è un'altra cosa e deve poter esistere.
    expect(build(:seo_page, url: page.url)).to be_valid
  end

  it "richiede le due date di avvistamento" do
    expect(build(:seo_page, first_seen_at: nil)).not_to be_valid
    expect(build(:seo_page, last_seen_at: nil)).not_to be_valid
  end

  it "#ok? guarda la risposta prima di ogni altra cosa" do
    expect(build(:seo_page)).to be_ok
    expect(build(:seo_page, :not_found)).not_to be_ok
  end

  it "distingue nessun h1 da troppi h1" do
    expect(build(:seo_page, :without_h1)).to be_missing_h1
    expect(build(:seo_page, h1s: %w[Uno Due])).to be_multiple_h1
    expect(build(:seo_page)).not_to be_multiple_h1
  end

  it "#noindex? legge le direttive senza farsi ingannare dal maiuscolo" do
    expect(build(:seo_page, robots_directives: "NoIndex, follow")).to be_noindex
    expect(build(:seo_page, robots_directives: "index, follow")).not_to be_noindex
    expect(build(:seo_page)).not_to be_noindex
  end

  it "i rilievi sopravvivono alla pagina potata" do
    page = create(:seo_page)
    issue = create(:seo_issue, site: page.site, page:)

    page.destroy!

    expect(issue.reload.page_id).to be_nil
    expect(issue.evidence["url"]).to be_present
  end
end
