# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::ResolveProject do
  let(:org) { create(:organization) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end
  let!(:project) { create(:project, organization: org, key: "DRRA") }

  describe "per chiave" do
    it "risolve un progetto visibile (case-insensitive)" do
      result = described_class.call(account: owner, key: "drra")
      expect(result).to be_ok
      expect(result.value).to eq(project)
    end

    it "chiave inesistente → R404-TELEGRAM-002" do
      result = described_class.call(account: owner, key: "ZZZZ")
      expect(result).to be_err
      expect(result.error.code).to eq("R404-TELEGRAM-002")
    end

    it "chiave di un progetto NON visibile (member senza assegnazione) → not found (anti-BOLA)" do
      member = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
      result = described_class.call(account: member, key: "DRRA")
      expect(result).to be_err
      expect(result.error.code).to eq("R404-TELEGRAM-002")
    end

    it "stessa chiave visibile in due org → R409-TELEGRAM-001 (ambigua)" do
      org2 = create(:organization)
      create(:membership, account: owner, organization: org2, role: :owner)
      create(:project, organization: org2, key: "DRRA")

      result = described_class.call(account: owner, key: "DRRA")
      expect(result).to be_err
      expect(result.error.code).to eq("R409-TELEGRAM-001")
    end

    it "god risolve la chiave anche senza membership (unscoped cross-org)" do
      god = create(:account, god: true)
      result = described_class.call(account: god, key: "DRRA")
      expect(result).to be_ok
      expect(result.value).to eq(project)
    end
  end

  describe "progetto attivo (nessuna chiave)" do
    it "usa telegram_project_id se ancora visibile" do
      owner.update!(telegram_project_id: project.id)
      result = described_class.call(account: owner, key: nil)
      expect(result).to be_ok
      expect(result.value).to eq(project)
    end

    it "nessun progetto attivo → R404-TELEGRAM-003" do
      result = described_class.call(account: owner, key: nil)
      expect(result).to be_err
      expect(result.error.code).to eq("R404-TELEGRAM-003")
    end

    it "progetto attivo non più visibile → R404-TELEGRAM-003 (anti-BOLA, non lo espone)" do
      member = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
      member.update!(telegram_project_id: project.id) # settato ma il member non ha accesso
      result = described_class.call(account: member, key: nil)
      expect(result).to be_err
      expect(result.error.code).to eq("R404-TELEGRAM-003")
    end
  end
end
