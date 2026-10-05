# frozen_string_literal: true

require "rails_helper"

# CYRA-933 — every New opens its form in the member modal: a request for the "modal" frame gets the
# form alone inside that frame, everything else keeps the full page.
RSpec.describe "New forms in the member modal", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:modal) { { "Turbo-Frame" => "modal" } }

  before do
    create(:membership, account: account, organization: org, role: :owner)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def doc = Nokogiri::HTML(response.body)

  it "answers the modal frame with the form alone, without breadcrumb or sidebar" do
    get new_member_group_path, headers: modal

    expect(doc.at_css("turbo-frame#modal [data-test='group-form']")).to be_present
    expect(doc.at_css("[data-test='member-sidebar'], aside")).to be_nil
    expect(doc.at_css("turbo-frame#modal nav[aria-label='Breadcrumb'], turbo-frame#modal [data-test='breadcrumb']")).to be_nil
  end

  it "keeps the full page for a direct visit" do
    get new_member_group_path

    expect(doc.at_css("turbo-frame#modal [data-test='group-form']")).to be_nil
    expect(doc.at_css("[data-test='group-form']")).to be_present
    expect(doc.at_css("dialog[data-test='member-modal']")).to be_present
    # A <dialog> does not inherit the page's text color: unreadable in dark without its own.
    expect(doc.css("dialog[data-test^='member-modal']").map { it["class"] }).to all(include("dark:text-zinc-100"))
  end

  it "keeps a failed save in the modal" do
    post member_groups_path, params: { name: "" }, headers: modal

    expect(response).to have_http_status(:unprocessable_content)
    expect(doc.at_css("turbo-frame#modal [data-test='group-form']")).to be_present
  end

  it "answers a successful save with a full page, so the browser leaves the modal" do
    post member_groups_path, params: { name: "DriverOne" }, headers: modal
    follow_redirect!(headers: modal)

    expect(doc.at_css("turbo-frame#modal")).to be_nil
  end

  it "gives the modal the text it shows while the form loads" do
    get member_groups_path

    dialog = doc.at_css("dialog[data-test='member-modal']")
    expect(dialog["data-ui--remote-modal-loading-value"]).to eq(I18n.t("shared.modal_loading"))
  end

  describe "a New stacked over another" do
    let(:stack) { { "Turbo-Frame" => "modal_stack" } }

    it "answers the stacked frame with the form alone" do
      get new_member_group_path, headers: stack

      expect(doc.at_css("turbo-frame#modal_stack [data-test='group-form']")).to be_present
      expect(doc.at_css("[data-test='member-sidebar']")).to be_nil
    end

    it "answers a stacked save with what was created, so the form below can pick it" do
      post member_groups_path, params: { name: "Stacked" }, headers: stack

      group = Projects::Group.find_by!(name: "Stacked", organization: org)
      created = doc.at_css("turbo-frame#modal_stack [data-modal-created]")
      expect([ created["data-value"], created["data-label"] ]).to eq([ group.id, "Stacked" ])
    end
  end

  describe "New ticket" do
    before { create(:project, organization: org) }

    it "asks for the wide modal" do
      get new_member_ticket_path, headers: modal

      expect(doc.at_css("turbo-frame#modal [data-modal-size='wide']")).to be_present
    end

    it "keeps the server errors inside the modal" do
      post member_tickets_path, params: { title: "" }, headers: modal

      expect(response).to have_http_status(:unprocessable_content)
      expect(doc.at_css("turbo-frame#modal [data-test='modal-flash-alert']")).to be_present
      expect(doc.at_css("turbo-frame#modal [data-test='ticket-title']")).to be_present
    end
  end
end
