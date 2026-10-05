# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member assistant dictation", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) } }
  let(:client) { instance_double(Ai::Llm::Client, transcribe: "The checkout times out on mobile.") }

  before do
    allow(Ai::Llm::Client).to receive(:new).and_return(client)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "answers with the text of what was said, and writes no message" do
    expect { post member_assistant_dictation_path, params: { audio: wav_upload } }
      .not_to change(Assistant::Message, :count)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("text" => "The checkout times out on mobile.")
  end

  it "says so when nothing was heard" do
    allow(client).to receive(:transcribe).and_return("  ")

    post member_assistant_dictation_path, params: { audio: wav_upload }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to eq(I18n.t("member.assistant.voice.not_heard"))
  end

  it "refuses a request without audio" do
    post member_assistant_dictation_path

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "refuses when voice is switched off" do
    allow(Ai::Feature).to receive(:disabled?).and_call_original
    allow(Ai::Feature).to receive(:disabled?).with(:assistant_voice).and_return(true)

    post member_assistant_dictation_path, params: { audio: wav_upload }

    expect(response).to have_http_status(:service_unavailable)
  end

  it "tells a provider failure without leaking it" do
    allow(client).to receive(:transcribe).and_raise(Ai::Llm::Client::Error.new("boom", code: "R502-LLM-007"))

    post member_assistant_dictation_path, params: { audio: wav_upload }

    expect(response).to have_http_status(:bad_gateway)
    expect(response.body).to eq(I18n.t("member.assistant.voice.failed"))
  end

  it "requires a login" do
    delete logout_path

    post member_assistant_dictation_path, params: { audio: wav_upload }

    expect(response).to redirect_to(login_path)
  end
end
