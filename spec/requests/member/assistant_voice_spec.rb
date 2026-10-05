# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member assistant voice", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) } }

  before { post login_path, params: { email: account.email, password: "Secret123!" } }

  def scope = Assistant::Conversation.for(account: account, organization: org)

  it "puts the audio on the conversation the panel shows and answers 204 (CYRA-908)" do
    recent = Assistant::Conversation.create!(account: account, organization: org, last_message_at: 1.minute.ago)
    Assistant::Conversation.create!(account: account, organization: org, last_message_at: 1.day.ago)

    post member_assistant_voice_path, params: { audio: wav_upload }

    expect(response).to have_http_status(:no_content)
    expect(recent.messages.sole).to be_status_transcribing
  end

  it "opens a conversation when there is none" do
    expect { post member_assistant_voice_path, params: { audio: wav_upload } }.to change { scope.count }.from(0).to(1)
  end

  it "never writes into another account's conversation" do
    other = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
    foreign = Assistant::Conversation.create!(account: other, organization: org, last_message_at: Time.current)

    post member_assistant_voice_path, params: { audio: wav_upload }

    expect(foreign.messages).to be_empty
  end

  # The panel's own microphone names the conversation on screen, even a brand-new empty one.
  it "puts the audio on the named conversation" do
    Assistant::Conversation.create!(account: account, organization: org, last_message_at: 1.minute.ago)
    empty = Assistant::Conversation.create!(account: account, organization: org)

    post member_assistant_voice_path, params: { audio: wav_upload, conversation_id: empty.id }

    expect(response).to have_http_status(:no_content)
    expect(empty.messages.sole).to be_status_transcribing
  end

  it "answers 404 for another account's conversation id" do
    other = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
    foreign = Assistant::Conversation.create!(account: other, organization: org, last_message_at: Time.current)

    post member_assistant_voice_path, params: { audio: wav_upload, conversation_id: foreign.id }

    expect(response).to have_http_status(:not_found)
    expect(foreign.messages).to be_empty
  end

  it "answers 415 with the reason for a format Whisper does not take" do
    post member_assistant_voice_path, params: { audio: wav_upload(content_type: "audio/webm") }

    expect(response).to have_http_status(:unsupported_media_type)
    expect(response.body).to eq(I18n.t("member.assistant.voice.errors.type", locale: account.effective_locale))
  end
end
