# frozen_string_literal: true

module Website
  # Landing marketing pubblica ("/" per i guest — dual root in config/routes/website.rb — e "/it").
  class HomeController < BaseController
    include MarketingGate

    def show
      @website_page = :home
      @features = FeaturePage.all
    end
  end
end
