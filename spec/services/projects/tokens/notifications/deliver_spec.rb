# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — la consegna dell'avviso di scadenza di una credenziale d'ingresso dati (CYRA-716), sui
# tre canali in un file solo. Lo stato della riga è il punto delicato: in app è consegnata nell'atto
# stesso di esistere, gli altri canali diventano "inviato" solo quando il messaggio esce davvero
# (CYRA-672) — scriverlo prima vorrebbe dire dichiarare consegnato un avviso ancora in coda.
RSpec.describe Projects::Tokens::Notifications::Deliver, type: :service do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:token) { create(:project_token, :expiring_soon, project: project) }
  let(:account) do
    create(:account, telegram_chat_id: "4242").tap do |a|
      create(:membership, account: a, organization: organization, role: :member)
    end
  end
  let(:content) do
    Projects::Tokens::Notifications::Content.new(title: "Titolo", body: "Corpo",
                                                 url: "/member/projects/x/tokens")
  end

  def opts(dedup_key: "token:1", **rest)
    { account: account, token: token, content: content, dedup_key: dedup_key, **rest }
  end

  describe "in app" do
    it "la riga è l'avviso stesso: nasce già consegnata" do
      result = described_class.in_app(**opts)

      expect(result).to be_ok
      expect(result.value.via_in_app?).to be(true)
      expect(result.value.status_sent?).to be(true)
      expect(result.value.delivered_at).to be_present
    end

    it "l'avviso compare subito nella campanella di chi lo riceve" do
      expect { described_class.in_app(**opts) }
        .to have_broadcasted_to("alerting:notifications:#{account.id}").twice
    end

    it "resta legato alla credenziale, al progetto e all'organizzazione giusti" do
      notifica = described_class.in_app(**opts).value

      expect(notifica.subject).to eq(token)
      expect(notifica.project).to eq(project)
      expect(notifica.organization).to eq(organization)
      expect(notifica.rule_id).to be_nil
    end
  end

  describe "email" do
    it "accoda il messaggio e lascia la riga in attesa di uscire davvero" do
      result = nil

      expect { result = described_class.email(**opts) }
        .to have_enqueued_mail(Alerting::AlertsMailer, :triggered)
      expect(result.value.status_pending?).to be(true)
    end

    it "ore silenziose → avviso trattenuto, nessun messaggio accodato" do
      result = nil

      expect { result = described_class.email(**opts(quiet: true)) }
        .not_to have_enqueued_mail(Alerting::AlertsMailer, :triggered)
      expect(result.value.status_held?).to be(true)
    end

    it "cadenza differita → avviso in coda per il riepilogo, nessun messaggio accodato" do
      result = nil

      expect { result = described_class.email(**opts(bucket: :daily)) }
        .not_to have_enqueued_mail(Alerting::AlertsMailer, :triggered)
      expect(result.value.status_queued?).to be(true)
    end
  end

  describe "telegram" do
    before { allow(::Telegram::Send).to receive(:call).and_return(Result.ok(true)) }

    it "manda il messaggio alla chat personale e segna l'avviso come inviato" do
      result = described_class.telegram(**opts)

      expect(result.value.status_sent?).to be(true)
      expect(::Telegram::Send).to have_received(:call).with(hash_including(chat_id: "4242", parse_mode: "HTML"))
    end

    it "quando Telegram rifiuta, l'avviso non risulta inviato" do
      allow(::Telegram::Send).to receive(:call)
        .and_return(Result.err(AppError.new("Bot Telegram non configurato", code: "R502-TELEGRAM-002",
                                            status: :bad_gateway)))

      notifica = described_class.telegram(**opts).value

      expect(notifica.status_failed?).to be(true)
      expect(notifica.delivered_at).to be_nil
    end

    # Le ore silenziose valgono per la sola email: gli altri canali non le hanno, e la cadenza
    # differita copre già il rinvio.
    it "cadenza differita → avviso in coda, nessun invio subito" do
      result = described_class.telegram(**opts(bucket: :weekly))

      expect(result.value.status_queued?).to be(true)
      expect(::Telegram::Send).not_to have_received(:call)
    end
  end

  describe "doppioni" do
    it "stessa chiave dell'avviso sullo stesso canale → nessuna seconda riga" do
      described_class.in_app(**opts)

      result = described_class.in_app(**opts)

      expect(result).to be_err
      expect(result.error).to eq(:duplicate)
      expect(Alerting::Notification.count).to eq(1)
    end

    it "due consegne insieme: la seconda si ferma sull'errore del database, non solleva" do
      allow_any_instance_of(Alerting::Notification).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

      expect(described_class.in_app(**opts)).to be_err
    end
  end
end
