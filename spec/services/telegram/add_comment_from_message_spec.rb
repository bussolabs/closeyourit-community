# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::AddCommentFromMessage do
  let(:org) { create(:organization) }
  let(:account) do
    create(:account, telegram_chat_id: "555").tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end
  let(:project) { create(:project, organization: org, key: "DRRA") }
  let!(:ticket) { create(:ticket, :plain_bug, organization: org, project: project) }

  before { allow(Telegram::Send).to receive(:call).and_return(Result.ok(true)) }

  def run(args, message: nil)
    described_class.call(account: account, chat_id: "555", args: args, message: message)
  end

  it "aggiunge un commento testuale al ticket per code" do
    expect { run("#{ticket.code} ci ho riprovato e succede ancora") }
      .to change { ticket.reload.comments.count }.by(1)
    comment = ticket.comments.last
    expect(comment.body).to eq("ci ho riprovato e succede ancora")
    expect(comment.author).to eq(account)
    expect(Telegram::Send).to have_received(:call).with(hash_including(text: include(ticket.code)))
  end

  it "code mancante → uso, nessun commento" do
    result = run("")
    expect(result).to be_err
    expect(ticket.reload.comments).to be_empty
  end

  it "testo vuoto senza foto → nessun commento" do
    result = run(ticket.code)
    expect(result).to be_err
    expect(ticket.reload.comments).to be_empty
  end

  it "se AddComment fallisce, avvisa e ritorna err" do
    allow(Ticketing::AddComment).to receive(:call).and_return(Result.err(AppError.new("non valido", code: "R422-COMMENT-001")))
    result = run("#{ticket.code} testo")
    expect(result).to be_err
    expect(Telegram::Send).to have_received(:call)
  end

  it "ticket non visibile → err, nessun commento (anti-BOLA)" do
    member = create(:account, telegram_chat_id: "556").tap { |a| create(:membership, account: a, organization: org, role: :member) }
    result = described_class.call(account: member, chat_id: "556", args: "#{ticket.code} testo")
    expect(result).to be_err
    expect(ticket.reload.comments).to be_empty
  end

  describe "con foto senza testo" do
    let(:upload) { Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/screenshot.png"), "image/png") }
    let(:message) { { "photo" => [ { "file_id" => "BIG" } ] } }

    it "crea un commento con corpo di default e allega la foto" do
      allow(Telegram::DownloadFile).to receive(:call).and_return(Result.ok(upload))

      expect { run(ticket.code, message: message) }.to change { ticket.reload.comments.count }.by(1)
      comment = ticket.comments.last
      expect(comment.files).to be_attached
      expect(comment.body).to eq(I18n.t("telegram.comment.photo_body", locale: account.effective_locale))
    end

    it "se il download della foto fallisce ma c'è testo, il commento resta (senza allegato)" do
      allow(Telegram::DownloadFile).to receive(:call)
        .and_return(Result.err(AppError.new("giù", code: "R502-TELEGRAM-004", status: :bad_gateway)))

      expect { run("#{ticket.code} guarda qui", message: message) }.to change { ticket.reload.comments.count }.by(1)
      comment = ticket.comments.last
      expect(comment.files).not_to be_attached
      expect(comment.body).to eq("guarda qui")
    end
  end
end
