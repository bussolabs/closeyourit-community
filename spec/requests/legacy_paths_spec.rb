# frozen_string_literal: true

require "rails_helper"

# Links already sent (emails, Telegram, saved bookmarks) still point at the multi-word addresses
# that the single-word rename replaced. They answer with a permanent redirect to the new address.
RSpec.describe "Legacy multi-word addresses", type: :request do
  it "redirects an old member address keeping ids and the query string" do
    get "/member/monitoring/error_groups/abc-123?tab=events&range=24h"

    expect(response).to have_http_status(:moved_permanently)
    expect(response).to redirect_to("/member/monitoring/error/abc-123?tab=events&range=24h")
  end

  it "rewrites a renamed segment into two segments" do
    get "/member/shared_secrets"

    expect(response).to redirect_to("/member/shared/secrets")
  end

  it "rewrites every renamed segment of the same address" do
    get "/member/projects/p-1/secret_assets"

    expect(response).to redirect_to("/member/projects/p-1/files")
  end

  it "keeps encoded characters as they arrived" do
    get "/member/monitoring/log_entries?q=a%20b%3Fc"

    expect(response).to redirect_to("/member/monitoring/logs?q=a%20b%3Fc")
  end

  it "keeps an encoded segment of the path encoded" do
    get "/member/monitoring/seo_sites/a%20b"

    expect(response).to redirect_to("/member/monitoring/sites/a%20b")
  end

  it "redirects the old two-factor pages" do
    get "/account/two_factor/setup"
    expect(response).to redirect_to("/account/2fa/setup")

    get "/login/two_factor"
    expect(response).to redirect_to("/login/2fa")
  end

  it "still answers not found for an address that never existed" do
    expect(Rails.application.routes.recognize_path("/member/monitoring/server_databases", method: :get))
      .to include(controller: "member/errors", action: "not_found")
  end
end
