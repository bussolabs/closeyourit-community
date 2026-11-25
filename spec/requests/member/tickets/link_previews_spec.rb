# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets::LinkPreviews", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:url) { "https://www.figma.com/file/abc/Checkout" }
  let(:ticket) { create(:ticket, organization: org, project:, description: "Design: #{url}") }
  let!(:preview) { create(:link_preview, :with_image, organization: org, url:) }
  let(:png) { File.binread(file_fixture("screenshot.png")) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project:)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "shows the card under the description, with title, site, our image and the link (AC-3)" do
    sign_in(member)

    get member_ticket_path(ticket)

    card = Nokogiri::HTML5(response.body).at_css("[data-test='ticket-link-preview']")
    expect(card["href"]).to eq(url)
    expect(card["target"]).to eq("_blank")
    expect(card.at_css("[data-test='ticket-link-preview-title']").text).to eq("Checkout redesign")
    expect(card.at_css("[data-test='ticket-link-preview-site']").text).to eq("Figma")
    expect(card.at_css("img")["src"]).to eq(image_member_ticket_link_preview_path(ticket, preview))
  end

  it "serves the image to whoever sees the ticket" do
    sign_in(member)

    get image_member_ticket_link_preview_path(ticket, preview)

    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(png.b)
    expect(response.media_type).to eq("image/png")
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
  end

  it "does not serve it once the account no longer sees the ticket" do
    Connections::ProjectMembership.where(account: member, project:).destroy_all
    sign_in(member)

    get image_member_ticket_link_preview_path(ticket, preview)

    expect(response).to have_http_status(:not_found)
  end

  it "does not serve the preview of a link the ticket no longer holds" do
    ticket.update_columns(description: "No links any more")
    sign_in(member)

    get image_member_ticket_link_preview_path(ticket, preview)

    expect(response).to have_http_status(:not_found)
  end

  it "does not serve another organization's preview of the same address" do
    foreign = create(:link_preview, :with_image, organization: create(:organization), url:)
    sign_in(member)

    get image_member_ticket_link_preview_path(ticket, foreign)

    expect(response).to have_http_status(:not_found)
  end

  it "the generic storage routes never serve it" do
    sign_in(member)

    get rails_blob_path(preview.image, disposition: :inline)

    expect(response).to have_http_status(:not_found)
    expect(response.body.b).not_to include(png.b)
  end
end
