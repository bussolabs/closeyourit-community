# frozen_string_literal: true

require "rails_helper"

# CYRA-1163 — a link in the description becomes a card after the save; internal addresses and pages
# without a title stay plain links. The background job runs inline so the page after the save shows it,
# except in the example where it ends after the page was rendered and the card arrives on the ticket stream.
RSpec.describe "Ticket link previews", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let(:owner) { create(:account) }
  let(:figma) { "https://www.figma.com/file/abc/Checkout" }
  let(:png) { File.binread(file_fixture("screenshot.png")) }

  before do
    create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber")
    create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber")
    create(:membership, account: owner, organization: org, role: :owner)
    allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ])
    allow(Ticketing::LinkPreviews::RefreshJob).to receive(:perform_later) do |**args|
      Ticketing::LinkPreviews::RefreshJob.perform_now(**args)
    end
  end

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def stub_page(url, head)
    stub_request(:get, url).to_return(status: 200, body: "<html><head>#{head}</head></html>",
                                      headers: { "Content-Type" => "text/html" })
  end

  def create_ticket(description)
    sign_in_as(owner)
    visit new_member_ticket_path
    select "Storefront", from: "project_id"
    fill_test "ticket-title", with: "Checkout design"
    fill_test "ticket-description", with: description
    click_on_test "ticket-submit"
    expect_test "member-ticket"
  end

  let(:figma_head) do
    '<meta property="og:title" content="Checkout redesign"><meta property="og:site_name" content="Figma">' \
      '<meta property="og:image" content="https://s3-figma.test/thumb.png">'
  end

  it "AC-1: a Figma link shows a card with title and image that opens the link" do
    stub_page(figma, figma_head)
    stub_request(:get, "https://s3-figma.test/thumb.png").to_return(status: 200, body: png,
                                                                    headers: { "Content-Type" => "image/png" })

    create_ticket("The new design: #{figma}")

    within("[data-test='ticket-link-preview']") do
      expect(page).to have_css("[data-test='ticket-link-preview-title']", text: "Checkout redesign")
      expect(page).to have_css("[data-test='ticket-link-preview-site']", text: "Figma")
      expect(page).to have_css("img[data-test='ticket-link-preview-image']")
    end
    card = find("[data-test='ticket-link-preview']")
    expect(card[:href]).to eq(figma)
    expect(card[:target]).to eq("_blank")

    # The image comes from our own route, not from the other site.
    visit find("[data-test='ticket-link-preview-image']")[:src]
    expect(page.driver.response.body.b).to eq(png.b)
  end

  it "AC-1: when the job ends after the page was rendered, the open page receives the card" do
    stub_page(figma, figma_head)
    stub_request(:get, "https://s3-figma.test/thumb.png").to_return(status: 200, body: png,
                                                                    headers: { "Content-Type" => "image/png" })
    # The job stays in the queue, as in production: the page of the save is rendered before it runs.
    allow(Ticketing::LinkPreviews::RefreshJob).to receive(:perform_later).and_call_original

    create_ticket("The new design: #{figma}")

    ticket = Ticketing::Ticket.find_by!(title: "Checkout design")
    slot = ActionView::RecordIdentifier.dom_id(ticket, :link_previews)
    expect(page).to have_no_css("[data-test='ticket-link-preview']")
    expect(page).to have_css("##{slot}", visible: :all)
    signed = page.all("turbo-cable-stream-source", visible: :all).map { |el| el["signed-stream-name"] }
    expect(signed.compact.filter_map { |name| Turbo::StreamsChannel.verified_stream_name(name) })
      .to include(Realtime::Streams.ticket(ticket))
    expect(Ticketing::LinkPreviews::RefreshJob).to have_been_enqueued.with(ticket_id: ticket.id)

    ActionCable.server.pubsub.clear
    Ticketing::LinkPreviews::RefreshJob.perform_now(ticket_id: ticket.id)

    # What the open page receives: a replace of the element it already holds, carrying the card.
    message = ActionCable.server.pubsub.broadcasts(Realtime::Streams.ticket(ticket)).map { |raw| JSON.parse(raw) }.join
    expect(message).to include(%(action="replace"), %(target="#{slot}"))
    update = Capybara.string(message[%r{<template>(.*)</template>}m, 1])
    expect(update).to have_css("##{slot}", visible: :all)
    card = update.find("[data-test='ticket-link-preview']")
    expect(card[:href]).to eq(figma)
    expect(card[:target]).to eq("_blank")
    expect(card).to have_css("[data-test='ticket-link-preview-title']", text: "Checkout redesign")
    expect(card).to have_css("img[data-test='ticket-link-preview-image']")
  end

  it "AC-2: a link to the internal network is never visited and stays a plain link" do
    internal = stub_request(:get, "http://10.0.0.12/dashboard")

    create_ticket("Look at http://10.0.0.12/dashboard")

    expect(internal).not_to have_been_requested
    expect(page).to have_no_css("[data-test='ticket-link-preview']")
    expect(page).to have_css("[data-test='ticket-description'] a[href='http://10.0.0.12/dashboard']")
  end

  it "AC-6: an image over the cap gives a card with title and site, without image" do
    stub_page(figma, figma_head)
    stub_request(:get, "https://s3-figma.test/thumb.png")
      .to_return(status: 200, body: "a" * 10_000_000, headers: { "Content-Type" => "image/png" })

    create_ticket("The new design: #{figma}")

    expect(page).to have_css("[data-test='ticket-link-preview-title']", text: "Checkout redesign")
    expect(page).to have_css("[data-test='ticket-link-preview-site']", text: "Figma")
    expect(page).to have_no_css("[data-test='ticket-link-preview-image']")
  end

  it "AC-7: a page without a title shows no card and the link stays plain" do
    stub_page("https://untitled.test/page", "")

    create_ticket("See https://untitled.test/page")

    expect(page).to have_no_css("[data-test='ticket-link-previews']")
    expect(page).to have_css("[data-test='ticket-description'] a[href='https://untitled.test/page']")
  end

  it "editing the description reads the new link" do
    stub_page(figma, figma_head)
    stub_request(:get, "https://s3-figma.test/thumb.png").to_return(status: 200, body: png)
    ticket = create(:ticket, organization: org, project:, description: "No links yet")
    sign_in_as(owner)

    visit edit_member_ticket_path(ticket)
    fill_test "ticket-description", with: "Now #{figma}"
    click_on_test "ticket-submit"
    expect_test "flash-notice"
    visit member_ticket_path(ticket)

    expect(page).to have_css("[data-test='ticket-link-preview-title']", text: "Checkout redesign")
  end
end
