# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — la consegna su Telegram di un avviso di chat, gemella di quella via email e in app.
# Il progetto dell'avviso si legge dalla conversazione: un canale di progetto lo porta, un messaggio
# diretto no, e in quel caso l'avviso deve restare senza progetto invece di attaccarsene uno.
RSpec.describe Chat::Notifications::Deliver, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:conversation) { create(:chat_conversation, organization: organization, contextable: project) }
  let(:message) { create(:chat_message, conversation: conversation, organization: organization) }
  let(:account) do
    create(:account, telegram_chat_id: "5566").tap do |a|
      create(:membership, account: a, organization: organization, role: :member)
    end
  end
  let(:content) { Chat::Notifications::Content.new(title: "Titolo", body: "Corpo", url: "/member/chat") }

  before { allow(::Telegram::Send).to receive(:call).and_return(Result.ok(true)) }

  def call(dedup_key: "telegram:1", bucket: nil, subject: message)
    described_class.telegram(account: account, message: subject, organization: organization,
                         event_type: :chat_mentioned, content: content,
                         dedup_key: dedup_key, bucket: bucket)
  end

  it "manda il messaggio alla chat personale e segna l'avviso come inviato" do
    result = call

    expect(result).to be_ok
    expect(result.value.via_telegram?).to be(true)
    expect(result.value.status_sent?).to be(true)
    expect(::Telegram::Send).to have_received(:call).with(hash_including(chat_id: "5566", parse_mode: "HTML"))
  end

  it "in un canale di progetto l'avviso porta con sé il progetto" do
    expect(call.value.project).to eq(project)
  end

  it "in un messaggio diretto l'avviso non ha nessun progetto" do
    diretta = create(:chat_conversation, :direct, organization: organization)
    messaggio = create(:chat_message, conversation: diretta, organization: organization)

    expect(call(subject: messaggio).value.project).to be_nil
  end

  it "quando Telegram rifiuta, l'avviso non risulta inviato" do
    allow(::Telegram::Send).to receive(:call)
      .and_return(Result.err(AppError.new("Bot Telegram non configurato", code: "R502-TELEGRAM-002",
                                          status: :bad_gateway)))

    notifica = call.value

    expect(notifica.status_failed?).to be(true)
    expect(notifica.delivered_at).to be_nil
  end

  it "cadenza differita → avviso in coda, nessun invio subito" do
    result = call(bucket: :weekly)

    expect(result.value.status_queued?).to be(true)
    expect(::Telegram::Send).not_to have_received(:call)
  end

  it "stessa chiave dell'avviso → nessun doppione, con un errore leggibile" do
    call

    result = call

    expect(result).to be_err
    expect(result.error.code).to eq("R409-CHAT-011")
    expect(Alerting::Notification.count).to eq(1)
  end

  it "due consegne insieme: la seconda si ferma sull'errore del database, non solleva" do
    allow_any_instance_of(Alerting::Notification).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

    expect(call).to be_err
  end
end
