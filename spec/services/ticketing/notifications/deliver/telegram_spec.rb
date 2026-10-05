# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — la consegna su Telegram di un avviso di ticket, gemella di quella via email e in app.
# CYRA-672: l'invio non solleva mai, restituisce un esito — buttarlo vorrebbe dire segnare "inviato"
# un avviso che non è mai partito.
RSpec.describe Ticketing::Notifications::Deliver, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:ticket) { create(:ticket, organization: organization, project: project) }
  let(:account) do
    create(:account, telegram_chat_id: "9911").tap do |a|
      create(:membership, account: a, organization: organization, role: :member)
    end
  end
  let(:content) { Ticketing::Notifications::Content.new(title: "Titolo", body: "Corpo", url: "/member/x") }

  before { allow(::Telegram::Send).to receive(:call).and_return(Result.ok(true)) }

  def call(dedup_key: "telegram:1", bucket: nil)
    described_class.telegram(account: account, ticket: ticket, organization: organization,
                         event_type: :ticket_commented, content: content,
                         dedup_key: dedup_key, bucket: bucket)
  end

  it "manda il messaggio alla chat personale e segna l'avviso come inviato" do
    result = call

    expect(result).to be_ok
    expect(result.value.via_telegram?).to be(true)
    expect(result.value.status_sent?).to be(true)
    expect(::Telegram::Send).to have_received(:call).with(hash_including(chat_id: "9911", parse_mode: "HTML"))
  end

  it "l'avviso resta legato al ticket e al progetto giusti" do
    notifica = call.value

    expect(notifica.subject).to eq(ticket)
    expect(notifica.project).to eq(project)
    expect(notifica.rule_id).to be_nil
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
    result = call(bucket: :daily)

    expect(result.value.status_queued?).to be(true)
    expect(::Telegram::Send).not_to have_received(:call)
  end

  it "stessa chiave dell'avviso → nessun doppione" do
    call

    expect(call).to be_err
    expect(Alerting::Notification.count).to eq(1)
  end

  it "due consegne insieme: la seconda si ferma sull'errore del database, non solleva" do
    allow_any_instance_of(Alerting::Notification).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

    result = call

    expect(result).to be_err
    expect(result.error).to eq(:duplicate)
  end
end
