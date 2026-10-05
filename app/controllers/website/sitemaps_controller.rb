# frozen_string_literal: true

module Website
  # Sitemap XML del sito marketing: ogni pagina × ogni locale come <url> dedicata, con gli
  # alternates hreflang incrociati (+ x-default → EN). Le status page pubbliche NON ci sono:
  # opt-in per-monitor, si condividono via link diretto.
  class SitemapsController < BaseController
    include MarketingGate

    def show
      pages = [ [ :home, nil ], *FeaturePage.all.map { |f| [ :feature, f.slug ] }, [ :integrations, nil ], [ :access_request, nil ], [ :privacy, nil ] ]
      @base_url = request.base_url
      @entries = pages.map do |page, slug|
        BaseController::LOCALES.index_with { |locale| view_context.website_page_path(page, locale: locale, slug: slug) }
      end
    end
  end
end
