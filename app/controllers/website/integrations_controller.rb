# frozen_string_literal: true

module Website
  # Pagina integrazioni del sito marketing (/integrations e /it/integrazioni):
  # SDK Ruby/Dart, CLI cyi, ingest da CI, compatibilità Sentry.
  class IntegrationsController < BaseController
    include MarketingGate

    def show
      @website_page = :integrations
    end
  end
end
