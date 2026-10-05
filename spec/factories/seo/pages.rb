# frozen_string_literal: true

FactoryBot.define do
  factory :seo_page, class: "Seo::Page" do
    site { create(:seo_site) }
    sequence(:url) { |n| "https://example.com/pagina-#{n}" }
    path { URI.parse(url).path }
    status_code { 200 }
    title { "Una pagina che si presenta" }
    meta_description { "Descrizione della pagina, lunga il giusto per non essere tagliata." }
    canonical_url { url }
    lang { "it" }
    h1s { [ "Una pagina che si presenta" ] }
    h2_count { 3 }
    word_count { 420 }
    internal_links_count { 8 }
    external_links_count { 2 }
    images_total { 4 }
    images_without_alt { 0 }
    html_bytes { 42_000 }
    response_time_ms { 180 }
    in_sitemap { true }
    discovered_from { "sitemap" }
    first_seen_at { 2.days.ago }
    last_seen_at { Time.current }

    trait :not_found do
      status_code { 404 }
      title { nil }
      h1s { [] }
      word_count { 0 }
    end

    trait :noindex do
      robots_directives { "noindex, follow" }
    end

    trait :without_h1 do
      h1s { [] }
    end

    trait :orphan do
      in_sitemap { true }
      internal_links_count { 0 }
      discovered_from { "sitemap" }
    end
  end
end
