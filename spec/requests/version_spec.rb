require "rails_helper"

RSpec.describe "Version", type: :request do
  describe "GET /version" do
    it "risponde 200 senza autenticazione con il contratto completo" do
      get "/version"

      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json.keys).to contain_exactly(
        "app", "tag", "sha", "short_sha", "build_time", "environment", "ruby_version", "rails_version"
      )
    end

    it "espone i valori dalle ENV APP_GIT_* quando presenti" do
      stub_const("ENV", ENV.to_hash.merge(
        "APP_GIT_TAG" => "v9.9.9",
        "APP_GIT_SHA" => "abc1234",
        "APP_BUILD_TIME" => "2026-06-26T00:00:00Z",
        "CLOSEYOURIT_ENVIRONMENT" => "staging",
      ))

      get "/version"

      json = response.parsed_body
      expect(json["tag"]).to eq("v9.9.9")
      expect(json["sha"]).to eq("abc1234")
      expect(json["short_sha"]).to eq("abc1234")
      expect(json["build_time"]).to eq("2026-06-26T00:00:00Z")
      expect(json["environment"]).to eq("staging")
    end

    it "usa fallback stabili quando le ENV di build non sono presenti" do
      stub_const("ENV", ENV.to_hash.except(
        "APP_GIT_TAG", "APP_GIT_SHA", "APP_BUILD_TIME", "CLOSEYOURIT_ENVIRONMENT"
      ))

      get "/version"

      expect(response.parsed_body).to include(
        "tag" => "unknown", "sha" => "unknown", "short_sha" => "unknown",
        "build_time" => "unknown", "environment" => Rails.env.to_s
      )
    end
  end
end
