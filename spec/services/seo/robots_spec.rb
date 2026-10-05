# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::Robots do
  it "senza robots.txt non è vietato niente, come per i motori veri" do
    robots = described_class.parse(nil)

    expect(robots).to be_allowed("/qualsiasi/cosa")
    expect(robots.sitemaps).to be_empty
  end

  it "rispetta i divieti del gruppo generico" do
    robots = described_class.parse(<<~TXT)
      User-agent: *
      Disallow: /admin
      Disallow: /privato
    TXT

    expect(robots).not_to be_allowed("/admin/utenti")
    expect(robots).not_to be_allowed("/privato")
    expect(robots).to be_allowed("/blog")
  end

  it "a parità di prefisso vince la regola più lunga, e a parità di lunghezza vince Allow" do
    robots = described_class.parse(<<~TXT)
      User-agent: *
      Disallow: /blog
      Allow: /blog/pubblico
    TXT

    expect(robots).not_to be_allowed("/blog/bozza")
    expect(robots).to be_allowed("/blog/pubblico/articolo")
  end

  it "il gruppo che ci nomina vince su quello generico" do
    robots = described_class.parse(<<~TXT)
      User-agent: *
      Disallow: /

      User-agent: CloseYourItBot
      Disallow: /admin
    TXT

    expect(robots).to be_allowed("/blog")
    expect(robots).not_to be_allowed("/admin")
  end

  it "raccoglie le sitemap dichiarate" do
    robots = described_class.parse(<<~TXT)
      Sitemap: https://sito.test/sitemap.xml
      Sitemap: https://sito.test/sitemap-news.xml
      User-agent: *
      Disallow:
    TXT

    expect(robots.sitemaps).to eq(%w[https://sito.test/sitemap.xml https://sito.test/sitemap-news.xml])
    # `Disallow:` senza valore è il modo standard di dire "prego, accomodati".
    expect(robots).to be_allowed("/")
  end

  it "ignora i commenti" do
    robots = described_class.parse(<<~TXT)
      # niente robot qui, grazie
      User-agent: *
      Disallow: /admin # area riservata
    TXT

    expect(robots).not_to be_allowed("/admin")
  end

  it "riconosce un sito che chiude la porta a tutti" do
    robots = described_class.parse("User-agent: *\nDisallow: /")

    expect(robots).to be_blocks_everything
    expect(robots).not_to be_allowed("/qualsiasi")
  end
end
