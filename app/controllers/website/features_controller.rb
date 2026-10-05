# frozen_string_literal: true

module Website
  # Pagina feature del sito marketing (/features/:slug e /it/funzionalita/:slug).
  # Slug fuori catalogo → 404 (stesso pattern head(:not_found) della status page).
  class FeaturesController < BaseController
    include MarketingGate

    def show
      @feature = FeaturePage.find(params[:slug])
      return head(:not_found) unless @feature

      @website_page = :feature
      @features = FeaturePage.all
    end
  end
end
