# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::DigestJob, type: :job do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }

  def queued(via:, bucket:, title: "N", account: self.account, org: organization)
    create(:alerting_notification, account: account, organization: org, via: via,
                                   status: :queued, digest_bucket: bucket, title: title)
  end

  describe "digest email" do
    it "raccoglie le email :queued daily → 1 mail di riepilogo e toglie le righe dalla coda" do
      a = queued(via: :email, bucket: :daily, title: "A")
      b = queued(via: :email, bucket: :daily, title: "B")

      expect { described_class.perform_now("daily", "email") }
        .to have_enqueued_mail(Notifications::DigestMailer, :summary).once

      # CYRA-672 — accodare non e' consegnare: le righe passano a :pending, cosi' escono dallo
      # scope :queued (il digest non le ripropone) e aspettano la conferma dell'osservatore.
      expect(a.reload).to be_status_pending
      expect(b.reload).to be_status_pending
    end

    it "vuoto → no-op (nessuna mail)" do
      expect { described_class.perform_now("daily", "email") }
        .not_to have_enqueued_mail(Notifications::DigestMailer, :summary)
    end

    it "idempotente: un secondo run non re-invia (righe già :sent)" do
      queued(via: :email, bucket: :daily)
      described_class.perform_now("daily", "email")

      expect { described_class.perform_now("daily", "email") }
        .not_to have_enqueued_mail(Notifications::DigestMailer, :summary)
    end

    it "il run daily NON tocca le righe weekly" do
      weekly = queued(via: :email, bucket: :weekly)
      described_class.perform_now("daily", "email")
      expect(weekly.reload).to be_status_queued
    end

    it "una mail per account distinto (due account, due mail)" do
      other = create(:account)
      queued(via: :email, bucket: :daily)
      queued(via: :email, bucket: :daily, account: other)

      expect { described_class.perform_now("daily", "email") }
        .to have_enqueued_mail(Notifications::DigestMailer, :summary).exactly(2).times
    end
  end

  describe "digest telegram" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
    end

    # CYRA-852 — l'owner col gruppo con argomenti riceve il riassunto nel generale del gruppo.
    it "owner col gruppo Telegram: il riassunto va nel gruppo, anche senza chat personale" do
      create(:membership, account: account, organization: organization, role: :owner)
      Alerting::TelegramGroup.create!(organization: organization, account: account, chat_id: "-100")
      n = queued(via: :telegram, bucket: :daily, title: "A")
      stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage")
             .with { |req| JSON.parse(req.body)["chat_id"] == "-100" }.to_return(status: 200)

      described_class.perform_now("daily", "telegram")

      expect(stub).to have_been_requested
      expect(n.reload).to be_status_sent
    end

    it "invia UN messaggio al chat_id dell'account e marca le righe :sent" do
      account.update!(telegram_chat_id: "700")
      queued(via: :telegram, bucket: :daily, title: "A")
      b = queued(via: :telegram, bucket: :daily, title: "B")
      stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 200)

      described_class.perform_now("daily", "telegram")

      expect(stub).to have_been_requested.once
      expect(b.reload).to be_status_sent
    end

    it "account scollegato tra accodamento e digest → niente invio, righe :skipped" do
      n = queued(via: :telegram, bucket: :daily) # account senza chat_id

      described_class.perform_now("daily", "telegram")

      # CYRA-672 — prima erano marcate :sent «per non accumulare», cioe' dichiarate consegnate
      # senza che partisse niente. :skipped dice la stessa cosa senza mentire: persa, definitiva.
      expect(n.reload).to be_status_skipped
    end

    it "compone testo HTML (header in grassetto + una riga per notifica) e invia con parse_mode HTML" do
      account.update!(telegram_chat_id: "700")
      queued(via: :telegram, bucket: :daily, title: "A")
      stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage")
             .with { |req|
               body = JSON.parse(req.body)
               body["parse_mode"] == "HTML" && body["text"].start_with?("<b>") && body["text"].include?("A")
             }
             .to_return(status: 200)

      described_class.perform_now("daily", "telegram")

      expect(stub).to have_been_requested
    end
  end
end
