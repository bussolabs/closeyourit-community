# frozen_string_literal: true

module Website
  # CYRA-698 — informativa privacy del sito e del prodotto (/privacy e /it/privacy). Pagina statica
  # servita dai locale: il testo è un contenuto legale, non un dato applicativo, e sta dove stanno
  # tutte le altre parole del sito.
  class PrivacyController < BaseController
    include MarketingGate

    def show
      @website_page = :privacy
    end
  end
end
