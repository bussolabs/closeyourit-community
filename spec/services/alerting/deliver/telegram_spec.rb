# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — la consegna di un avviso su Telegram. Gemello del canale email: la riga della notifica
# nasce sempre, il messaggio parte solo se l'avviso è immediato. CYRA-672: l'invio non solleva mai,
# restituisce un esito — buttarlo vorrebbe dire scrivere "inviata" su un avviso mai partito.
RSpec.describe Alerting::Deliver, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:group) { create(:error_group, project: project) }
  let(:account) do
    create(:account, telegram_chat_id: "12345").tap do |a|
      create(:membership, account: a, organization: organization, role: :member)
    end
  end
  let(:rule) { create(:alerting_rule, organization: organization, event_type: :error_new) }
  let(:content) { Alerting::Content.new(title: "Titolo", body: "Corpo", url: "/x", project: project) }

  # In test nessun messaggio parte davvero: senza bot configurato l'invio risponde con un errore.
  before { allow(::Telegram::Send).to receive(:call).and_return(Result.ok(true)) }

  def call(dedup_key: "telegram:1", bucket: nil, event_type: "error_new")
    described_class.telegram(rule: rule, account: account, event_type: event_type, subject: group,
                         content: content, dedup_key: dedup_key, bucket: bucket)
  end

  describe "consegna immediata" do
    it "manda il messaggio e segna la notifica come inviata" do
      result = call

      expect(result).to be_ok
      expect(result.value.via_telegram?).to be(true)
      expect(result.value.status_sent?).to be(true)
      expect(result.value.delivered_at).to be_present
    end

    it "scrive alla chat personale del destinatario, in formato ricco" do
      call

      expect(::Telegram::Send).to have_received(:call)
        .with(hash_including(chat_id: "12345", parse_mode: "HTML"))
    end

    it "congela sulla notifica il testo leggibile dell'avviso" do
      notifica = call.value

      expect(notifica.title).to eq("Titolo")
      expect(notifica.body).to eq("Corpo")
      expect(notifica[:url]).to eq("/x")
      expect(notifica.subject).to eq(group)
      expect(notifica.project).to eq(project)
    end

    # CYRA-672 — l'esito dell'invio conta: una notifica che non è partita non può risultare inviata.
    it "quando Telegram rifiuta, la notifica risulta non consegnata" do
      allow(::Telegram::Send).to receive(:call)
        .and_return(Result.err(AppError.new("Bot Telegram non configurato", code: "R502-TELEGRAM-002",
                                            status: :bad_gateway)))

      notifica = call.value

      expect(notifica.status_failed?).to be(true)
      expect(notifica.status_sent?).to be(false)
      expect(notifica.delivered_at).to be_nil
    end

    it "anche quando Telegram rifiuta l'avviso resta scritto, non sparisce" do
      allow(::Telegram::Send).to receive(:call)
        .and_return(Result.err(AppError.new("Telegram irraggiungibile", code: "R502-TELEGRAM-001",
                                            status: :bad_gateway)))

      expect(call).to be_ok
      expect(Alerting::Notification.count).to eq(1)
    end
  end

  describe "cadenza differita (riepilogo giornaliero o settimanale)" do
    it "mette la notifica in coda e non manda niente subito" do
      result = call(bucket: :daily)

      expect(result).to be_ok
      expect(result.value.status_queued?).to be(true)
      expect(result.value.digest_bucket).to eq("daily")
      expect(::Telegram::Send).not_to have_received(:call)
    end

    it "vale anche per gli avvisi gravi: la cadenza non si scavalca" do
      result = call(event_type: "uptime_down", bucket: :weekly)

      expect(result.value.status_queued?).to be(true)
      expect(::Telegram::Send).not_to have_received(:call)
    end
  end

  describe "doppioni" do
    it "stessa chiave dell'avviso → nessuna seconda notifica" do
      call

      expect(call).to be_err
      expect(Alerting::Notification.count).to eq(1)
    end

    it "chiavi diverse → due notifiche distinte" do
      call(dedup_key: "telegram:1")

      expect(call(dedup_key: "telegram:2")).to be_ok
      expect(Alerting::Notification.count).to eq(2)
    end

    it "due consegne insieme: la seconda si ferma sull'errore del database, non solleva" do
      allow_any_instance_of(Alerting::Notification).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

      result = call

      expect(result).to be_err
      expect(result.error).to eq(:duplicate)
    end
  end
end
