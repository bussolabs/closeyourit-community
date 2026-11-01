# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Wikitech::Entries", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before { create(:membership, account:, organization:, role: :member) }

  describe "GET /cli/v1/wikitech/entries" do
    it "lists only the organization's cards with filters and pagination" do
      engine = create(:wikitech_entry, organization:, name: "Godot", categories: [ "game dev" ], verification: :verified)
      create(:wikitech_entry, organization:, name: "Plane", categories: [ "ticketing" ])
      create(:wikitech_entry, name: "Other org card")

      get "/cli/v1/wikitech/entries", headers: headers
      expect(response.parsed_body["data"].map { |e| e["name"] }).to contain_exactly("Godot", "Plane")
      expect(response.parsed_body["meta"]).to include("total" => 2)

      get "/cli/v1/wikitech/entries", params: { category: "game dev", verification: "verified" }, headers: headers
      expect(response.parsed_body["data"].map { |e| e["id"] }).to eq([ engine.id ])
    end

    it "searches and says how it searched" do
      create(:wikitech_entry, organization:, name: "Plane", summary: "Ticket tracker")
      allow(Embeddings::QueryVector).to receive(:call).and_return(Result.err(AppError.new("down", code: "R502-AI-001")))

      get "/cli/v1/wikitech/entries", params: { q: "ticket" }, headers: headers

      expect(response.parsed_body["data"].map { |e| e["name"] }).to eq([ "Plane" ])
      expect(response.parsed_body["meta"]["search"]).to eq("like")
    end
  end

  describe "GET /cli/v1/wikitech/entries/:id" do
    it "shows the whole card with repository data and sources" do
      entry = create(:wikitech_entry, organization:, name: "Godot", facts: [ "Free" ],
                                      repo_meta: { "full_name" => "godotengine/godot", "stars" => 10, "description" => "x" })
      create(:wikitech_source, entry:, quote: "Open source.")

      get "/cli/v1/wikitech/entries/#{entry.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data).to include("name" => "Godot", "facts" => [ "Free" ], "stars" => 10)
      expect(data["repo"]).to eq("full_name" => "godotengine/godot", "stars" => 10)
      expect(data["sources"].first).to include("label" => "TikTok @github.signals", "quote" => "Open source.")
    end

    it "answers 404 for a card of another organization" do
      get "/cli/v1/wikitech/entries/#{create(:wikitech_entry).id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-WIKITECH-001")
    end
  end
end
