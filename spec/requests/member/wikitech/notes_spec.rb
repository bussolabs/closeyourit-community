# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Wikitech::Notes", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    post login_path, params: { email: member.email, password: "Secret123!" }
  end

  it "shows the form" do
    get new_member_wikitech_note_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="wikitech-note-body"', 'data-test="wikitech-note-submit"')
  end

  it "saves a note with links one per line and says the cards come soon" do
    post member_wikitech_notes_path, params: { body: "Godot is an engine.", source_label: "Article",
                                               links: "https://github.com/godotengine/godot\nhttps://godotengine.org" }

    expect(response).to redirect_to(member_wikitech_root_path)
    expect(flash[:notice]).to eq(I18n.t("member.wikitech.notes.saved"))
    expect(org.wikitech_notes.last.links).to eq([ "https://github.com/godotengine/godot", "https://godotengine.org" ])
  end

  it "says when the same note was already there" do
    create(:wikitech_note, organization: org, body: "Godot is an engine.", source_url: nil)

    post member_wikitech_notes_path, params: { body: "Godot is an engine." }

    expect(flash[:notice]).to eq(I18n.t("member.wikitech.notes.duplicate"))
  end

  it "shows the error on the form" do
    post member_wikitech_notes_path, params: { body: "" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t("wikitech.errors.body_blank"))
  end
end
