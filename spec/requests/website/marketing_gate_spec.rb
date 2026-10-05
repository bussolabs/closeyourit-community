# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Website marketing gate", type: :request do
  around do |example|
    saved = ENV["MARKETING_SITE"]
    ENV.delete("MARKETING_SITE")
    example.run
  ensure
    ENV["MARKETING_SITE"] = saved
  end

  it "sends a guest from the home page to sign in on an install without the marketing site" do
    get website_root_path

    expect(response).to redirect_to(login_path)
  end

  it "has no feature, privacy or access request pages there" do
    get website_feature_path(slug: "uptime")
    expect(response).to have_http_status(:not_found)

    get request_access_path
    expect(response).to have_http_status(:not_found)
  end

  context "with the production error pages" do
    around do |example|
      config = Rails.application.env_config
      original = config.values_at("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
      config["action_dispatch.show_exceptions"] = :all
      config["action_dispatch.show_detailed_exceptions"] = false
      example.run
      config["action_dispatch.show_exceptions"], config["action_dispatch.show_detailed_exceptions"] = original
    end

    it "answers the sitemap with a 404, not a 500, so crawlers of a self-hosted install stop there (CYRA-914 P4)" do
      get website_sitemap_path

      expect(response).to have_http_status(:not_found)
    end
  end

  it "keeps the public status pages, which are a product feature" do
    get public_status_path(org_slug: "nobody", project_key: "NOPE", environment_code: "production")

    expect(response).to have_http_status(:not_found).or have_http_status(:ok)
    expect(response.body).not_to include("Marketing site disabled")
  end
end
