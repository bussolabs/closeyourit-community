# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Chat message edits", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:author) { create(:account) }
  let(:recipient) { create(:account) }
  let(:conversation) do
    Chat::Conversations::FindOrCreateDirect.call(organization:, account_a: author, account_b: recipient).value
  end
  let(:message) { create(:chat_message, conversation:, author:, body: "Original") }

  before do
    allow_n_plus_one do
      [ author, recipient ].each do |account|
        create(:membership, account:, organization:, role: :member)
        create(:project_membership, account:, project:)
      end
    end
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "edits an own message and returns to the conversation" do
    sign_in(author)
    get edit_member_chat_conversation_message_path(conversation, message)
    html = Nokogiri::HTML5(response.body)
    expect(html.at_css('textarea[name="body"]').text).to eq("Original")
    stamp = html.at_css('input[name="expected_updated_at"]')["value"]

    patch member_chat_conversation_message_path(conversation, message), params: { body: "Corrected", expected_updated_at: stamp }

    expect(response).to redirect_to(member_chat_conversation_path(conversation))
    expect(message.reload.body).to eq("Corrected")
  end

  it "returns a validation error for an empty message" do
    sign_in(author)
    patch member_chat_conversation_message_path(conversation, message),
          params: { body: " ", expected_updated_at: message.updated_at.iso8601(6) }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include('id="chat-message-error"')
    expect(message.reload.body).to eq("Original")
  end

  it "keeps the submitted draft on a stale form without overwriting the latest message" do
    stamp = message.updated_at.iso8601(6)
    travel 1.second do
      message.update!(body: "Newer correction")
    end
    sign_in(author)
    patch member_chat_conversation_message_path(conversation, message), params: { body: "My draft", expected_updated_at: stamp }

    expect(response).to have_http_status(:conflict)
    expect(Nokogiri::HTML5(response.body).at_css('textarea[name="body"]').text).to eq("My draft")
    expect(message.reload.body).to eq("Newer correction")
  end

  it "denies another participant both the form and the update" do
    sign_in(recipient)
    get edit_member_chat_conversation_message_path(conversation, message)
    expect(response).to have_http_status(:not_found)
    patch member_chat_conversation_message_path(conversation, message),
          params: { body: "Changed", expected_updated_at: message.updated_at.iso8601(6) }
    expect(response).to have_http_status(:not_found)
    expect(message.reload.body).to eq("Original")
  end

  it "hides a conversation from an outsider" do
    outsider = create(:account)
    create(:membership, account: outsider, organization:, role: :member)
    sign_in(outsider)
    get edit_member_chat_conversation_message_path(conversation, message)
    expect(response).to have_http_status(:not_found)
  end

  it "does not reopen a deleted message" do
    message.soft_delete!
    sign_in(author)
    get edit_member_chat_conversation_message_path(conversation, message)
    expect(response).to have_http_status(:not_found)
  end
end
