# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::TelegramLinkCode, type: :model do
  let(:account) { create(:account) }

  describe ".issue" do
    it "conia un codice valido per il deep-link Telegram (<=64 char, [A-Za-z0-9_-])" do
      code = described_class.issue(account: account)

      expect(code.length).to be <= 64
      expect(code).to match(/\A[A-Za-z0-9_-]+\z/)
      expect(described_class.find_by(code: code).account).to eq(account)
    end

    it "usa il TTL di default (Accounts::Constants::TTL_TELEGRAM_LINK)" do
      freeze_time do
        code = described_class.issue(account: account)
        expect(described_class.find_by(code: code).expires_at).to eq(Accounts::Constants::TTL_TELEGRAM_LINK.from_now)
      end
    end

    it "purga i codici scaduti al momento del conio" do
      stale = described_class.create!(account: account, code: "stale-code", expires_at: 2.hours.ago)

      described_class.issue(account: account)

      expect(described_class.where(id: stale.id)).to be_empty
    end
  end

  describe ".consume" do
    it "risolve un codice attivo al suo account e lo consuma (single-use)" do
      code = described_class.issue(account: account)

      expect(described_class.consume(code)).to eq(account)
      expect(described_class.find_by(code: code)).to be_nil
      expect(described_class.consume(code)).to be_nil # già consumato
    end

    it "ritorna nil per un codice scaduto (e non lo usa)" do
      expired = described_class.create!(account: account, code: "expired-code", expires_at: 1.second.ago)

      expect(described_class.consume(expired.code)).to be_nil
    end

    it "ritorna nil per un codice inesistente" do
      expect(described_class.consume("nope")).to be_nil
    end

    it "ritorna nil per codice blank/nil" do
      expect(described_class.consume("")).to be_nil
      expect(described_class.consume(nil)).to be_nil
    end
  end

  describe "cancellazione account" do
    it "distrugge i codici pendenti (FK on_delete cascade + dependent)" do
      described_class.issue(account: account)

      expect { account.destroy }.to change(described_class, :count).by(-1)
    end
  end

  # CYRA-852 — i codici del gruppo e quelli della chat personale non si scambiano.
  describe "codici del gruppo con argomenti" do
    let(:organization) { create(:organization) }

    it "consume non accetta il codice di un gruppo, consume_for_group sì" do
      code = described_class.issue(account: account, organization: organization)

      expect(described_class.consume(code)).to be_nil
      expect(described_class.consume_for_group(code)).to have_attributes(account: account, organization: organization)
      expect(described_class.consume_for_group(code)).to be_nil
    end

    it "consume_for_group non accetta il codice della chat personale" do
      code = described_class.issue(account: account)

      expect(described_class.consume_for_group(code)).to be_nil
      expect(described_class.consume(code)).to eq(account)
    end
  end
end
