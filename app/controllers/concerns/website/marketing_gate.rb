# frozen_string_literal: true

module Website
  # The marketing pages (landing, features, integrations, privacy, access requests, sitemap) moved
  # to the separate public site (closeyourit-nuxt, CYRA-917). They answer only where
  # MARKETING_SITE=true — closeyour.it until the site is live there. Anywhere else the guest home
  # goes to sign in and the other pages do not exist.
  module MarketingGate
    extend ActiveSupport::Concern

    included do
      before_action :require_marketing_site
    end

    def self.enabled? = ENV["MARKETING_SITE"] == "true"

    private

    def require_marketing_site
      return if MarketingGate.enabled?
      return redirect_to(login_path) if controller_name == "home"

      raise ActionController::RoutingError, "Marketing site disabled"
    end
  end
end
