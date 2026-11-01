# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Wikitech::Entries", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }

  before { create(:membership, account: member, organization: org, role: :member) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET /member/wikitech" do
    it "shows the empty state when the organization has no card" do
      sign_in(member)

      get member_wikitech_root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="wikitech-empty"', 'data-test="wikitech-new-note"')
      expect(response.body).not_to include('data-test="wikitech-ask"')
    end

    it "lists only the organization's cards with counts, ask panel and filters" do
      create(:wikitech_entry, organization: org, name: "Godot", categories: [ "game dev" ], verification: :verified,
                              repo_url: "https://github.com/godotengine/godot", repo_meta: { "stars" => 1234 })
      create(:wikitech_entry, organization: org, name: "Plane", categories: [ "ticketing" ])
      create(:wikitech_entry, name: "Other org card")
      sign_in(member)

      get member_wikitech_root_path

      expect(response.body).to include("Godot", "Plane", "1,234", 'data-test="wikitech-counts"', 'data-test="wikitech-ask"')
      expect(response.body).not_to include("Other org card")

      get member_wikitech_root_path, params: { category: [ "ticketing" ] }
      expect(response.body).to include("Plane")
      expect(response.body).not_to include(">Godot<")

      get member_wikitech_root_path, params: { verification: [ "verified" ] }
      expect(response.body).to include(">Godot<")
      expect(response.body).not_to include(">Plane<")
    end

    it "sorts by a column and keeps the filtered panel when nothing matches" do
      create(:wikitech_entry, organization: org, name: "Alpha", sources_count: 1)
      create(:wikitech_entry, organization: org, name: "Beta", sources_count: 5)
      allow(Embeddings::QueryVector).to receive(:call).and_return(Result.err(AppError.new("down", code: "R502-AI-001")))
      sign_in(member)

      get member_wikitech_root_path, params: { sort: "-sources" }
      expect(response.body.index(">Beta<")).to be < response.body.index(">Alpha<")

      get member_wikitech_root_path, params: { q: "nothing like this" }
      expect(response.body).to include('data-test="wikitech-no-match"', 'data-test="wikitech-toolbar"')

      get member_wikitech_root_path, params: { q: "alpha", sort: "name" }
      expect(response.body).to include(">Alpha<")
    end
  end

  describe "GET /member/wikitech/entries/:id" do
    it "shows the card with facts, details, links and sources" do
      entry = create(:wikitech_entry, organization: org, name: "Godot", facts: [ "Free alternative to Unity" ],
                                      repo_url: "https://github.com/godotengine/godot", links: [ "https://godotengine.org" ],
                                      verification: :verified,
                                      repo_meta: { "license" => "MIT", "language" => "C++", "pushed_at" => "2026-10-30T10:00:00Z" })
      create(:wikitech_source, entry: entry, quote: "Open source and free.")
      sign_in(member)

      get member_wikitech_entry_path(entry)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Free alternative to Unity", "MIT", "C++", "godotengine.org", "Open source and free.",
                                       'data-test="wikitech-open-repo"', "TikTok @github.signals")
    end

    it "does not show a card of another organization" do
      sign_in(member)

      get member_wikitech_entry_path(create(:wikitech_entry))

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /member/wikitech/ask" do
    it "queues the question and answers 202 with the request id" do
      sign_in(member)

      expect { post member_wikitech_ask_path, params: { question: "games?" }, as: :json }
        .to have_enqueued_job(Ai::RunJob)

      expect(response).to have_http_status(:accepted)
      expect(Ai::Request.last).to have_attributes(kind: "wikitech_ask", args: { "question" => "games?" })
    end

    it "refuses a blank question" do
      sign_in(member)

      post member_wikitech_ask_path, params: { question: " " }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-WIKITECH-004")
    end
  end
end
