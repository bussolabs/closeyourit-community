# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ingest::RawSentryBody do
  it "leaves body bytes and headers untouched while disabling protocol parameter parsing" do
    body = StringIO.new("_method=DELETE&private=value")
    env = Rack::MockRequest.env_for("/api/123/envelope/", method: "POST", input: body,
                                   "CONTENT_TYPE" => "application/x-www-form-urlencoded")
    endpoint = lambda do |request|
      expect(request["REQUEST_METHOD"]).to eq("POST")
      expect(request["CONTENT_TYPE"]).to eq("application/x-www-form-urlencoded")
      expect(request["rack.input"].pos).to eq(0)
      expect(ActionDispatch::Request.new(request).request_parameters).to eq({})
      [ 200, {}, [] ]
    end
    described_class.new(Rack::MethodOverride.new(endpoint)).call(env)
  end

  it "preserves form parsing and method override on other application routes" do
    env = Rack::MockRequest.env_for("/member/example", method: "POST", input: "_method=DELETE&name=example",
                                   "CONTENT_TYPE" => "application/x-www-form-urlencoded")
    endpoint = lambda do |request|
      expect(request["REQUEST_METHOD"]).to eq("DELETE")
      expect(Rack::Request.new(request).POST["name"]).to eq("example")
      [ 200, {}, [] ]
    end
    described_class.new(Rack::MethodOverride.new(endpoint)).call(env)
  end

  it "does not match non-POST or non-protocol paths" do
    [ [ "GET", "/api/1/envelope" ], [ "POST", "/api/1/envelope.json" ],
      [ "POST", "/api/v1/projects/1/events" ] ].each do |method, path|
      env = Rack::MockRequest.env_for(path, method: method)
      described_class.new(->(request) { [ 200, {}, [] ] }).call(env)
      expect(env).not_to have_key("action_dispatch.request.request_parameters")
    end
  end

  it "protects all artifact upload routes including their optional Rails format" do
    %w[source_maps proguard_maps native_symbols].product([ "", ".json", ".xml", ".json/" ]).each do |kind, format|
      path = "/cli/v1/projects/00000000-0000-4000-8000-000000000001/artifacts/#{kind}#{format}"
      expect(Rails.application.routes.recognize_path(path, method: :post)).to include(action: "create")
      env = Rack::MockRequest.env_for(path, method: "POST", input: "private body")
      described_class.new(->(_request) { [ 200, {}, [] ] }).call(env)
      expect(env.fetch("action_dispatch.request.request_parameters")).to eq({})
      expect(env.fetch("rack.input").pos).to eq(0)
    end
  end

  it "does not disable parsing for artifact reads, item mutations or adjacent routes" do
    [ [ "GET", "/cli/v1/projects/1/artifacts/proguard_maps.json" ],
      [ "POST", "/cli/v1/projects/1/artifacts/source_maps_extra.json" ],
      [ "POST", "/cli/v1/projects/1/artifacts/proguard_maps/1.json" ],
      [ "POST", "/cli/v1/projects/1/artifacts/proguard_maps.json/extra" ] ].each do |method, path|
      env = Rack::MockRequest.env_for(path, method: method)
      described_class.new(->(_request) { [ 200, {}, [] ] }).call(env)
      expect(env).not_to have_key("action_dispatch.request.request_parameters")
    end
  end
end
