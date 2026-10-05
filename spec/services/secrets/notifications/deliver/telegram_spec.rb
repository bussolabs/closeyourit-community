# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Notifications::Deliver do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:variable) { create(:secret_variable, project: project) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:content) { Secrets::Notifications::Content.new(title: "Titolo", body: "Corpo", url: "/member/vault/rotation") }

  # In test nessun messaggio Telegram parte davvero: senza bot configurato Telegram::Send
  # restituisce un errore. Prima di CYRA-672 il servizio buttava quel valore, quindi le prove
  # sulla consegna passavano senza che nulla fosse consegnato. Ora l'esito conta, e va dichiarato.
  before { allow(::Telegram::Send).to receive(:call).and_return(Result.ok(true)) }

  def call(dedup_key: "telegram:1", bucket: nil)
    described_class.telegram(account: account, variable: variable, organization: organization,
                         event_type: :secret_rotation_due, content: content, dedup_key: dedup_key, bucket: bucket)
  end

  it "consegna immediata (bucket nil) → Result.ok, notifica via telegram segnata sent" do
    result = call
    expect(result).to be_ok
    notification = result.value
    expect(notification.via_telegram?).to be(true)
    expect(notification.status_sent?).to be(true)
    expect(notification.subject).to eq(variable)
    expect(notification.rule_id).to be_nil
  end

  # CYRA-672 — Telegram::Send non solleva mai: ha un rescue e RESTITUISCE un Result. Buttare quel
  # valore vuol dire segnare "inviata" una notifica che non e' partita.
  it "quando Telegram rifiuta, la notifica NON risulta inviata" do
    allow(::Telegram::Send).to receive(:call)
      .and_return(Result.err(AppError.new("Bot Telegram non configurato", code: "R502-TELEGRAM-002",
                                          status: :bad_gateway)))

    notification = call.value
    expect(notification.status_sent?).to be(false)
    expect(notification.status_failed?).to be(true)
    expect(notification.delivered_at).to be_nil
  end

  it "bucket presente (cadenza daily/weekly) → notifica :queued, nessun invio immediato" do
    result = call(bucket: :daily)
    expect(result).to be_ok
    expect(result.value.status_queued?).to be(true)
  end

  it "duplicato sulla dedup_key (save = false per uniqueness) → Result.err(:duplicate)" do
    call
    expect(call).to be_err
  end

  it "race concorrente: save solleva RecordNotUnique → Result.err(:duplicate) (rescue)" do
    allow_any_instance_of(Alerting::Notification).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

    result = call

    expect(result).to be_err
    expect(result.error).to eq(:duplicate)
  end

  describe "subject/project generico (CYRA-138 Fase B: eventi senza una variabile viva)" do
    it "accetta subject:/project: espliciti (es. il progetto, per secret_deleted/secret_sync_failed)" do
      result = described_class.telegram(
        account: account, subject: project, project: project, organization: organization,
        event_type: :secret_deleted, content: content, dedup_key: "telegram:generic"
      )

      expect(result).to be_ok
      expect(result.value.subject).to eq(project)
      expect(result.value.project).to eq(project)
    end
  end
end
