# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Wikitech::Asks", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  before { create(:membership, account:, organization:, role: :member) }

  it "answers with the cited cards of the organization" do
    entry = create(:wikitech_entry, organization:, name: "Godot")
    allow(Wikitech::Ask).to receive(:call) do |scope:, question:|
      expect(scope.to_a).to eq([ entry ])
      expect(question).to eq("games?")
      Result.ok(Wikitech::Ask::Answer.new(answer: "Godot.", entries: [ entry ], insufficient: false))
    end

    post "/cli/v1/wikitech/asks", params: { question: "games?" }, headers: headers, as: :json

    expect(response.parsed_body["data"]).to include("answer" => "Godot.", "insufficient" => false)
    expect(response.parsed_body["data"]["entries"].map { |e| e["name"] }).to eq([ "Godot" ])
  end

  it "answers 422 on a blank question" do
    post "/cli/v1/wikitech/asks", params: { question: "" }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-WIKITECH-004")
  end
end
