# frozen_string_literal: true

require "rails_helper"

# Web addresses use single-word segments. The machine channels (/api, /cli) keep their contracts:
# the CLI, the SDKs and the server agent call them from outside.
RSpec.describe "Single-word web paths", type: :request do
  it "has no multi-word segment outside the machine channels and the guide slugs" do
    offenders = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.sub("(.:format)", "")
      next if path.start_with?("/api", "/cli", "/rails", "/member/guides/")
      next if route.defaults[:controller].to_s.start_with?("turbo/") || path == "/_system_test_entrypoint"

      path if path.split("/").reject { |segment| segment.start_with?(":", "*", "(") }.any? { |segment| segment.include?("_") }
    end

    expect(offenders.uniq).to be_empty
  end

  it "serves the new address and redirects the old one" do
    expect(Rails.application.routes.recognize_path("/member/monitoring/error", method: :get))
      .to include(controller: "member/monitoring/error_groups", action: "index")
    expect(Routing::LegacyPaths.rewrite("/member/monitoring/error_groups")).to eq("/member/monitoring/error")
  end
end
