# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — the issue and board calls of the GitHub client.
RSpec.describe Github::Client do
  let(:rsa) { OpenSSL::PKey::RSA.new(2048) }
  let(:installation_id) { 999 }
  let(:issues_url) { "https://api.github.test/repos/bussolabs/app/issues" }
  let(:graphql_url) { "https://api.github.test/graphql" }

  subject(:client) do
    described_class.new(app_id: "42", private_key: rsa.to_pem, base_url: "https://api.github.test")
  end

  before do
    Rails.cache.clear
    stub_request(:post, "https://api.github.test/app/installations/#{installation_id}/access_tokens")
      .to_return(status: 201, body: { token: "ghs_installtoken" }.to_json)
  end

  def graphql_returns(*datas)
    stub_request(:post, graphql_url).to_return(*datas.map { |data| { status: 200, body: { data: }.to_json } })
  end

  def card(overrides = {})
    {
      "id" => "PVTI_1", "project" => { "id" => "PVT_1" },
      "content" => { "__typename" => "Issue", "id" => "I_1", "number" => 7, "repository" => { "databaseId" => 55 } },
      "fieldValues" => { "nodes" => [ { "optionId" => "OPT_1", "field" => { "id" => "F_1" } }, {}, nil ] }
    }.merge(overrides)
  end

  describe "#repository_issues" do
    it "reads the open issues oldest first and drops the pull requests" do
      stub_request(:get, issues_url)
        .with(query: { "state" => "open", "per_page" => "100", "page" => "1", "sort" => "created", "direction" => "asc" })
        .to_return(status: 200, body: [ { "number" => 1 }, { "number" => 2, "pull_request" => {} } ].to_json)

      expect(client.repository_issues(installation_id, "bussolabs/app")).to eq([ { "number" => 1 } ])
    end

    it "reads the issues changed since a moment, by last change" do
      since = Time.utc(2026, 11, 5, 10)
      stub_request(:get, issues_url)
        .with(query: { "state" => "all", "per_page" => "100", "page" => "2", "sort" => "updated",
                       "direction" => "asc", "since" => "2026-11-05T10:00:00Z" })
        .to_return(status: 200, body: [].to_json)

      expect(client.repository_issues(installation_id, "bussolabs/app", state: "all", since:, page: 2)).to eq([])
    end
  end

  describe "#issue_comments" do
    it "reads one page of comments" do
      stub_request(:get, "#{issues_url}/7/comments").with(query: { "per_page" => "100", "page" => "1" })
        .to_return(status: 200, body: [ { "id" => 1 } ].to_json)

      expect(client.issue_comments(installation_id, "bussolabs/app", 7)).to eq([ { "id" => 1 } ])
    end

    it "reads only the comments changed since a moment" do
      stub_request(:get, "#{issues_url}/7/comments")
        .with(query: { "per_page" => "100", "page" => "1", "since" => "2026-11-05T10:00:00Z" })
        .to_return(status: 200, body: [].to_json)

      expect(client.issue_comments(installation_id, "bussolabs/app", 7, since: Time.utc(2026, 11, 5, 10))).to eq([])
    end
  end

  describe "#board" do
    it "picks the column field named Status" do
      fields = [ { "id" => "F_0", "name" => "Priority", "options" => [] }, { "id" => "F_1", "name" => "status", "options" => [] }, {} ]
      graphql_returns({ node: { title: "Roadmap", fields: { nodes: fields } } })

      expect(client.board(installation_id, "PVT_1")).to eq(title: "Roadmap", field: fields[1])
    end

    it "is nil when the board is gone" do
      graphql_returns({ node: nil })

      expect(client.board(installation_id, "PVT_1")).to be_nil
    end
  end

  describe "#board_items" do
    it "reads every page and keeps only the issue cards" do
      graphql_returns(
        { node: { items: { pageInfo: { hasNextPage: true, endCursor: "C1" }, nodes: [ card ] } } },
        { node: { items: { pageInfo: { hasNextPage: false }, nodes: [ card("content" => { "__typename" => "DraftIssue" }) ] } } }
      )

      expect(client.board_items(installation_id, "PVT_1")).to eq(
        [ { item_id: "PVTI_1", board_id: "PVT_1", issue_node_id: "I_1", number: 7, repo_id: 55, options: { "F_1" => "OPT_1" } } ]
      )
    end

    it "is empty when the board is gone" do
      graphql_returns({ node: nil })

      expect(client.board_items(installation_id, "PVT_1")).to eq([])
    end
  end

  describe "#board_item and #issue_board_items" do
    it "reads one card" do
      graphql_returns({ node: card })

      expect(client.board_item(installation_id, "PVTI_1")).to include(item_id: "PVTI_1", number: 7)
    end

    it "a card that is not an issue reads as nil" do
      graphql_returns({ node: card("content" => { "__typename" => "PullRequest" }) })

      expect(client.board_item(installation_id, "PVTI_1")).to be_nil
    end

    it "reads the cards of an issue" do
      graphql_returns({ node: { projectItems: { nodes: [ card ] } } })

      expect(client.issue_board_items(installation_id, "I_1").map { |item| item[:board_id] }).to eq(%w[PVT_1])
    end
  end

  describe "issue writes" do
    it "creates, updates and comments an issue, and deletes a comment" do
      opened = stub_request(:post, issues_url).with(body: { title: "T", body: "B" }.to_json)
                                              .to_return(status: 201, body: { number: 7 }.to_json)
      update = stub_request(:patch, "#{issues_url}/7").to_return(status: 200, body: { number: 7 }.to_json)
      comment = stub_request(:post, "#{issues_url}/7/comments").to_return(status: 201, body: { id: 1 }.to_json)
      delete = stub_request(:delete, "#{issues_url}/comments/1").to_return(status: 404, body: "")

      client.create_issue(installation_id, "bussolabs/app", title: "T", body: "B")
      client.update_issue(installation_id, "bussolabs/app", 7, { title: "T2" })
      client.create_issue_comment(installation_id, "bussolabs/app", 7, body: "Ciao")
      client.delete_issue_comment(installation_id, "bussolabs/app", 1)

      [ opened, update, comment, delete ].each { |request| expect(request).to have_been_requested }
    end

    it "moves and adds a board card" do
      graphql_returns({ addProjectV2ItemById: { item: { id: "PVTI_9" } } }, { updateProjectV2ItemFieldValue: {} })

      expect(client.add_board_item(installation_id, "PVT_1", "I_1")).to eq("PVTI_9")
      client.move_board_item(installation_id, "PVT_1", "PVTI_9", "F_1", "OPT_1")
      expect(a_request(:post, graphql_url)).to have_been_made.twice
    end
  end
end
