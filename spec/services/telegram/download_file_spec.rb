# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::DownloadFile do
  let(:token) { "BOT123" }
  let(:png) { File.binread(Rails.root.join("spec/fixtures/files/screenshot.png")) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return(token)
  end

  def stub_get_file(file_path: "photos/file_1.jpg", status: 200)
    body = status == 200 ? { ok: true, result: { file_path: file_path } }.to_json : "nope"
    stub_request(:get, %r{https://api\.telegram\.org/bot#{token}/getFile}).to_return(status: status, body: body)
  end

  def stub_download(file_path: "photos/file_1.jpg", status: 200, body: nil)
    stub_request(:get, "https://api.telegram.org/file/bot#{token}/#{file_path}")
      .to_return(status: status, body: body || png)
  end

  it "scarica il file e ritorna un uploadable valido per AttachToTicket" do
    stub_get_file
    stub_download

    result = described_class.call(file_id: "FILEID", filename: "shot.png")

    expect(result).to be_ok
    upload = result.value
    expect(upload.original_filename).to eq("shot.png")
    expect(upload.size).to eq(png.bytesize)
    expect(upload).to respond_to(:tempfile)
  end

  it "senza filename deriva un nome dall'estensione del file_path" do
    stub_get_file(file_path: "documents/report.pdf")
    stub_download(file_path: "documents/report.pdf", body: "%PDF-1.4 fake")

    result = described_class.call(file_id: "FILEID")
    expect(result).to be_ok
    expect(result.value.original_filename).to end_with(".pdf")
  end

  it "bot non configurato → R502-TELEGRAM-002" do
    allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("")
    result = described_class.call(file_id: "FILEID")
    expect(result).to be_err
    expect(result.error.code).to eq("R502-TELEGRAM-002")
  end

  it "file_id mancante → R422-TELEGRAM-006" do
    result = described_class.call(file_id: "")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-TELEGRAM-006")
  end

  it "getFile non-200 → R502-TELEGRAM-004" do
    stub_get_file(status: 500)
    result = described_class.call(file_id: "FILEID")
    expect(result).to be_err
    expect(result.error.code).to eq("R502-TELEGRAM-004")
  end

  it "download del binario non-200 → R502-TELEGRAM-004" do
    stub_get_file
    stub_download(status: 404, body: "missing")
    result = described_class.call(file_id: "FILEID")
    expect(result).to be_err
    expect(result.error.code).to eq("R502-TELEGRAM-004")
  end

  it "errore di rete (timeout) → R502-TELEGRAM-004, nessuna eccezione propagata" do
    stub_request(:get, %r{https://api\.telegram\.org/bot#{token}/getFile}).to_timeout
    result = described_class.call(file_id: "FILEID")
    expect(result).to be_err
    expect(result.error.code).to eq("R502-TELEGRAM-004")
  end
end
