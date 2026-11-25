# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::LinkPreviews", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:url) { "https://www.figma.com/file/abc/Checkout" }
  let(:ticket) { create(:ticket, project:, organization:, description: "Design: #{url} and https://plain.test/") }
  let!(:preview) { create(:link_preview, :with_image, organization:, url:) }
  let(:png) { File.binread(file_fixture("screenshot.png")) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:image_path) { "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/link_previews/#{preview.id}/image" }

  it "the ticket detail lists the previews with title, site and our image address (AC-3)" do
    get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}", headers: headers

    expect(response).to have_http_status(:ok)
    previews = response.parsed_body.dig("data", "link_previews")
    expect(previews).to eq([ { "url" => url, "title" => "Checkout redesign", "description" => nil,
                               "site_name" => "Figma", "image_url" => image_path } ])
  end

  it "the ticket list does not carry previews" do
    ticket
    get "/cli/v1/projects/#{project.id}/tickets", headers: headers

    expect(response.parsed_body["data"].first).not_to have_key("link_previews")
  end

  it "the image address serves our copy" do
    get image_path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(png.b)
    expect(response.media_type).to eq("image/png")
  end

  it "another organization's preview is not found from this ticket" do
    foreign = create(:link_preview, :with_image, organization: create(:organization), url:)

    get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/link_previews/#{foreign.id}/image", headers: headers

    expect(response).to have_http_status(:not_found)
  end
end
