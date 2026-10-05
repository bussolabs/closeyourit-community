# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::PostVoiceMessage do
  let(:conversation) { create(:assistant_conversation) }

  def post(audio = wav_upload) = described_class.call(conversation: conversation, audio: audio)

  it "creates a transcribing user message with the audio and queues the transcription (CYRA-908)" do
    result = nil
    expect { result = post }.to have_enqueued_job(Assistant::TranscribeJob)

    message = result.value
    expect(message).to be_role_user
    expect(message).to be_status_transcribing
    expect(message).to be_transcribed
    expect(message.audio).to be_attached
    expect(conversation.reload.last_message_at).to be_present
  end

  it "refuses a missing upload" do
    expect(post(nil).error.code).to eq(Assistant::Constants::NO_AUDIO_CODE)
  end

  it "refuses an upload over the size cap" do
    stub_const("Assistant::Constants::MAX_AUDIO_BYTES", 100)
    expect(post.error.code).to eq(Assistant::Constants::AUDIO_TOO_LARGE_CODE)
  end

  it "refuses a format Whisper does not take" do
    expect(post(wav_upload(content_type: "audio/webm")).error.code).to eq(Assistant::Constants::AUDIO_TYPE_CODE)
  end

  it "stops before writing anything when the voice switch is off" do
    Settings::Global.instance.update!(ai_assistant_voice_enabled: false)
    expect { expect(post).to be_err }.not_to change(Assistant::Message, :count)
  end

  it "stops when the chat switch is off" do
    Settings::Global.instance.update!(ai_assistant_chat_enabled: false)
    expect(post).to be_err
  end
end
