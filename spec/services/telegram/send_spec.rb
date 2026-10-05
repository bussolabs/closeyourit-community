# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::Send do
  it "err R502-TELEGRAM-002 se il token del bot non è configurato" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return(nil)

    result = described_class.call(chat_id: "1", text: "ciao")

    expect(result).to be_err
    expect(result.error.code).to eq("R502-TELEGRAM-002")
  end

  context "con bot configurato" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
    end

    it "invia sendMessage e ritorna ok su 200" do
      stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 200)

      result = described_class.call(chat_id: "42", text: "ciao")

      expect(result).to be_ok
      expect(stub).to have_been_requested
    end

    it "non include parse_mode nel body quando non è passato (testo plain)" do
      stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage")
             .with { |req| !JSON.parse(req.body).key?("parse_mode") }
             .to_return(status: 200)

      described_class.call(chat_id: "42", text: "ciao")

      expect(stub).to have_been_requested
    end

    it "include parse_mode HTML nel body quando passato" do
      stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage")
             .with { |req| JSON.parse(req.body)["parse_mode"] == "HTML" }
             .to_return(status: 200)

      described_class.call(chat_id: "42", text: "<b>ciao</b>", parse_mode: "HTML")

      expect(stub).to have_been_requested
    end

    it "err R502-TELEGRAM-001 su HTTP non-200 (loggato, fire-and-forget)" do
      stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 403)

      result = described_class.call(chat_id: "42", text: "ciao")

      expect(result).to be_err
      expect(result.error.code).to eq("R502-TELEGRAM-001")
    end

    it "err R502-TELEGRAM-003 se il chat_id è vuoto" do
      result = described_class.call(chat_id: "", text: "ciao")

      expect(result).to be_err
      expect(result.error.code).to eq("R502-TELEGRAM-003")
    end
  end
end
