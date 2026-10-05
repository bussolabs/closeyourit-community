# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Authenticated telemetry read-back", type: :request do
  let(:project) { create(:project) }
  let(:environment) { create(:environment, organization: project.organization).tap { |item| project.environments << item } }

  def credential(scopes: [ "read" ])
    Projects::Tokens::Issue.call(project:, environment:, name: "Read-back", host: "localhost", scopes:).value
  end

  def headers(scopes: [ "read" ])
    { "Authorization" => "Bearer #{credential(scopes:)[:secret]}" }
  end

  shared_examples "a scoped telemetry collection" do |factory, parent_factory, parent_path, child_path|
    let(:group) { create(parent_factory, project:) }
    let(:path) { "/api/v1/#{parent_path}/#{group.id}/#{child_path}" }

    it "returns an empty collection with pagination metadata" do
      get path, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("data" => [], "meta" => include("total" => 0))
    end

    (1..3).each do |page|
      it "reads page #{page} in stable order when timestamps are equal" do
        records = create_list(factory, 3, group:, project:, occurred_at: Time.utc(2026, 10, 3),
                                            payload: { "context" => { "run" => "certification" } })
        get path, params: { per: 1, page: }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["meta"]).to include("total" => 3, "total_pages" => 3)
        expect(response.parsed_body["data"].first["payload"]).to eq("context" => { "run" => "certification" })
        expected_id = records.map(&:id).sort.reverse.fetch(page - 1)
        expect(response.parsed_body["data"].pluck("id")).to eq([ expected_id ])
      end
    end

    it "does not read another project's group" do
      foreign_group = create(parent_factory)
      create(factory, group: foreign_group)
      get "/api/v1/#{parent_path}/#{foreign_group.id}/#{child_path}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "rejects an ingest-only credential" do
      get path, headers: headers(scopes: [ "ingest" ])
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-AUTH-002")
    end

    it "rejects a public key and a missing credential" do
      public_key = credential[:token].public_key
      get path, headers: { "X-Sentry-Auth" => "Sentry sentry_key=#{public_key}" }
      expect(response).to have_http_status(:unauthorized)
      get path
      expect(response).to have_http_status(:unauthorized)
    end
  end

  include_examples "a scoped telemetry collection", :error_event, :error_group, "error_groups", "events"

  context "performance samples" do
    include_examples "a scoped telemetry collection", :metric_sample, :metric_group, "metric_groups", "samples"
  end

  context "usage symbols" do
    let(:path) { "/api/v1/projects/#{project.id}/usages" }

    it "returns zero, one and several persisted symbols with exact filters" do
      read_headers = headers
      get path, headers: read_headers
      expect(response.parsed_body["data"]).to eq([])
      symbol = Usage::Symbol.create!(project:, kind: "custom", symbol: "certification.run", environment: "test",
                                     first_seen_at: Time.current, last_seen_at: Time.current, hits_count: 1)
      get path, headers: read_headers
      expect(response.parsed_body["data"]).to contain_exactly(include("id" => symbol.id, "symbol" => "certification.run"))
      Usage::Symbol.create!(project:, kind: "route", symbol: "OrdersController#index", environment: "staging",
                            first_seen_at: Time.current, last_seen_at: Time.current, hits_count: 2)
      get path, params: { kind: "custom", environment: "test" }, headers: read_headers
      expect(response.parsed_body["meta"]["total"]).to eq(1)
      get path, headers: read_headers
      expect(response.parsed_body["meta"]["total"]).to eq(2)
    end

    it "pins the project and requires read scope" do
      get "/api/v1/projects/#{create(:project).id}/usages", headers: headers
      expect(response).to have_http_status(:not_found)
      get path, headers: headers(scopes: [ "ingest" ])
      expect(response).to have_http_status(:forbidden)
      get path
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
