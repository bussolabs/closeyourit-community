# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::TranscribeJob do
  let(:conversation) { create(:assistant_conversation) }
  let(:message) { Assistant::PostVoiceMessage.call(conversation: conversation, audio: wav_upload).value }
  let(:client) { instance_double(Ai::Llm::Client) }

  before { allow(Ai::Llm::Client).to receive(:new).and_return(client) }

  def perform = described_class.perform_now(message_id: message.id)

  it "writes the text, purges the audio and starts the reply (CYRA-908)" do
    allow(client).to receive(:transcribe).and_return("Apri un ticket su CYFL")

    expect { perform }.to have_enqueued_job(Assistant::ConverseJob)

    message.reload
    expect(message).to be_status_complete
    expect(message.content).to eq("Apri un ticket su CYFL")
    expect(message.audio).not_to be_attached
    expect(conversation.reload.title).to eq("Apri un ticket su CYFL")
  end

  # The account language is not the spoken one (an English account can dictate in Italian).
  it "lets Whisper detect the spoken language" do
    allow(client).to receive(:transcribe).and_return("hi")
    perform
    expect(client).to have_received(:transcribe).with(audio: anything, filename: "voice.wav")
  end

  it "fails as not heard on an empty transcription, and starts no reply" do
    allow(client).to receive(:transcribe).and_return("")

    expect { perform }.not_to have_enqueued_job(Assistant::ConverseJob)
    expect(message.reload.error_kind).to eq(:not_heard)
    expect(message.audio).not_to be_attached
  end

  it "fails with the gateway code when the AI server is down, and still purges the audio" do
    allow(client).to receive(:transcribe)
      .and_raise(Ai::Llm::Client::Error.new("down", code: Ai::Llm::Client::UNAVAILABLE_CODE))

    perform

    message.reload
    expect(message).to be_status_failed
    expect(message.error_code).to eq(Ai::Llm::Client::UNAVAILABLE_CODE)
    expect(message.audio).not_to be_attached
  end

  it "does nothing for a message that is not transcribing anymore" do
    allow(client).to receive(:transcribe)
    message.update!(status: :complete, content: "done")
    perform
    expect(client).not_to have_received(:transcribe)
  end

  it "never logs the transcribed text" do
    allow(client).to receive(:transcribe).and_return("secret words")
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:info)
    perform
    expect(Rails.logger).not_to have_received(:info).with(/secret words/)
    expect(Rails.logger).not_to have_received(:warn).with(/secret words/)
  end
end
