# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Wikitech::Notes", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:payload) do
    { body: "Godot is an open-source engine for 2D and 3D games.", source_label: "TikTok @github.signals",
      source_url: "https://www.tiktok.com/@github.signals/video/1", links: [ "https://github.com/godotengine/godot" ] }
  end

  before { create(:membership, account:, organization:, role: :member) }

  it "refuses a request without a token" do
    post "/cli/v1/wikitech/notes", params: payload, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it "stores a note for a plain member and answers 201" do
    post "/cli/v1/wikitech/notes", params: payload, headers: headers, as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body["data"]).to include("status" => "pending",
                                                    "links" => [ "https://github.com/godotengine/godot" ])
    expect(response.parsed_body["data"]).not_to have_key("body")
    expect(organization.wikitech_notes.count).to eq(1)
  end

  it "answers 200 with meta.duplicate when the same note comes again" do
    post "/cli/v1/wikitech/notes", params: payload, headers: headers, as: :json
    post "/cli/v1/wikitech/notes", params: payload, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["meta"]).to eq("duplicate" => true)
    expect(organization.wikitech_notes.count).to eq(1)
  end

  it "answers 422 with the error code on a blank body" do
    post "/cli/v1/wikitech/notes", params: payload.merge(body: ""), headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-WIKITECH-001")
  end
end
