require "rails_helper"

RSpec.describe Types::TicketStatus, type: :model do
  describe "factory" do
    it "produce uno status valido" do
      expect(build(:ticket_status)).to be_valid
    end

    it "non è animato di default" do
      expect(build(:ticket_status).animated).to be(false)
    end
  end

  describe "validazioni" do
    it "richiede code" do
      expect(build(:ticket_status, code: nil)).not_to be_valid
    end

    it "richiede label" do
      expect(build(:ticket_status, label: nil)).not_to be_valid
    end

    it "richiede color" do
      expect(build(:ticket_status, color: nil)).not_to be_valid
    end

    it "rifiuta un code con formato non valido" do
      expect(build(:ticket_status, code: "In Review!")).not_to be_valid
    end

    it "normalizza il code (downcase + underscore)" do
      status = create(:ticket_status, code: "  In Review  ")
      expect(status.code).to eq("in_review")
    end
  end

  describe "unicità code per organizzazione" do
    it "rifiuta code duplicato nella stessa org" do
      org = create(:organization)
      create(:ticket_status, organization: org, code: "open")
      expect(build(:ticket_status, organization: org, code: "open")).not_to be_valid
    end

    it "permette lo stesso code in org diverse" do
      create(:ticket_status, organization: create(:organization), code: "open")
      expect(build(:ticket_status, organization: create(:organization), code: "open")).to be_valid
    end
  end

  describe "scope" do
    it ".active esclude i non attivi" do
      org = create(:organization)
      active = create(:ticket_status, organization: org, active: true)
      create(:ticket_status, organization: org, active: false)
      expect(described_class.active).to contain_exactly(active)
    end

    it ".ordered ordina per position" do
      org = create(:organization)
      second = create(:ticket_status, organization: org, position: 2)
      first = create(:ticket_status, organization: org, position: 1)
      expect(described_class.ordered.to_a).to eq([ first, second ])
    end
  end

  describe "dipendenze" do
    it "blocca l'eliminazione se referenziato da un ticket" do
      status = create(:ticket_status)
      create(:ticket, organization: status.organization, status: status)
      expect { status.destroy }.not_to change(described_class, :count)
      expect(status.errors[:base]).to be_present
    end
  end

  # CYRA-392 — la label localizzata: i code di default sono tradotti in it/en; uno status custom
  # dell'org ricade sulla label del DB. Il code non si tocca mai (filtri e URL condivisi).
  describe "#display_label" do
    it "traduce i code di default nella lingua corrente" do
      status = build(:ticket_status, code: "in_review", label: "In Review")

      expect(I18n.with_locale(:it) { status.display_label }).to eq("In revisione")
      expect(I18n.with_locale(:en) { status.display_label }).to eq("In Review")
    end

    it "ricade sulla label del DB per un code personalizzato" do
      status = build(:ticket_status, code: "wontfix", label: "Won't Fix")

      expect(I18n.with_locale(:it) { status.display_label }).to eq("Won't Fix")
    end
  end
end
