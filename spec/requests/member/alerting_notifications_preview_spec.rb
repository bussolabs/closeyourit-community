# frozen_string_literal: true

require "rails_helper"

# The bell's preview panel (CYRA-898): the latest five own notifications, loaded into a frame.
RSpec.describe "Member::AlertingNotifications preview", type: :request do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:doc) { Nokogiri::HTML(response.body) }

  before do
    create(:membership, account: account, organization: organization, role: :member)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # The bell loads the panel as a frame request, so the answer comes without the page layout.
  def get_preview
    get preview_member_alerting_notifications_path, headers: { "Turbo-Frame" => "notifications_preview" }
  end

  def own_notification(**attrs)
    create(:alerting_notification, { organization: organization, account: account, via: :in_app }.merge(attrs))
  end

  it "lists the latest five own notifications inside the preview frame" do
    6.times { |index| own_notification(title: "Alert #{index}", created_at: index.minutes.ago) }

    get_preview

    expect(response).to have_http_status(:ok)
    frame = doc.at_css("turbo-frame#notifications_preview")
    expect(frame.css("[data-test='notifications-preview-row']").size).to eq(5)
    expect(frame.text).to include("Alert 0")
    expect(frame.text).not_to include("Alert 5")
  end

  it "never shows another account's notifications" do
    other = create(:account)
    create(:membership, account: other, organization: organization, role: :member)
    create(:alerting_notification, organization: organization, account: other, via: :in_app, title: "Someone else")

    get_preview

    expect(response.body).not_to include("Someone else")
    expect(doc.at_css("[data-test='notifications-preview-empty']")).to be_present
  end

  it "offers mark all as read and the full list, both leaving the frame" do
    own_notification(title: "Boom")

    get_preview

    read_all = doc.at_css("form[action='#{read_all_member_alerting_notifications_path}']")
    expect(read_all["data-turbo-frame"]).to eq("_top")
    see_all = doc.at_css("a[data-test='notifications-preview-all']")
    expect(see_all["href"]).to eq(member_alerting_notifications_path)
    expect(see_all["data-turbo-frame"]).to eq("_top")
  end

  it "marking all as read from the bell returns to the page it came from" do
    own_notification(title: "Boom")

    patch read_all_member_alerting_notifications_path, headers: { "HTTP_REFERER" => "http://www.example.com/member/tickets" }

    expect(response).to redirect_to("http://www.example.com/member/tickets")
  end
end
