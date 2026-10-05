require "rails_helper"

RSpec.describe Types::TicketPriority, type: :model do
  describe "factory" do
    it "produce una priority valida" do
      expect(build(:ticket_priority)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede code" do
      expect(build(:ticket_priority, code: nil)).not_to be_valid
    end

    it "richiede label" do
      expect(build(:ticket_priority, label: nil)).not_to be_valid
    end

    it "richiede color" do
      expect(build(:ticket_priority, color: nil)).not_to be_valid
    end

    it "rifiuta un code con formato non valido" do
      expect(build(:ticket_priority, code: "High!")).not_to be_valid
    end

    it "normalizza il code (downcase + underscore)" do
      priority = create(:ticket_priority, code: "  Very High  ")
      expect(priority.code).to eq("very_high")
    end
  end

  describe "unicità code per organizzazione" do
    it "rifiuta code duplicato nella stessa org" do
      org = create(:organization)
      create(:ticket_priority, organization: org, code: "high")
      expect(build(:ticket_priority, organization: org, code: "high")).not_to be_valid
    end

    it "permette lo stesso code in org diverse" do
      create(:ticket_priority, organization: create(:organization), code: "high")
      expect(build(:ticket_priority, organization: create(:organization), code: "high")).to be_valid
    end
  end

  describe "scope" do
    it ".active esclude i non attivi" do
      org = create(:organization)
      active = create(:ticket_priority, organization: org, active: true)
      create(:ticket_priority, organization: org, active: false)
      expect(described_class.active).to contain_exactly(active)
    end

    it ".ordered ordina per position" do
      org = create(:organization)
      second = create(:ticket_priority, organization: org, position: 2)
      first = create(:ticket_priority, organization: org, position: 1)
      expect(described_class.ordered.to_a).to eq([ first, second ])
    end
  end

  describe "dipendenze" do
    it "blocca l'eliminazione se referenziata da un ticket" do
      priority = create(:ticket_priority)
      create(:ticket, organization: priority.organization, priority: priority)
      expect { priority.destroy }.not_to change(described_class, :count)
      expect(priority.errors[:base]).to be_present
    end
  end

  # CYRA-392 — label localizzata per i code di default (low/medium/high); una priorità custom ricade
  # sulla label del DB.
  describe "#display_label" do
    it "traduce i code di default nella lingua corrente" do
      priority = build(:ticket_priority, code: "high", label: "High")

      expect(I18n.with_locale(:it) { priority.display_label }).to eq("Alta")
      expect(I18n.with_locale(:en) { priority.display_label }).to eq("High")
    end

    it "ricade sulla label del DB per un code personalizzato" do
      priority = build(:ticket_priority, code: "urgentissima", label: "Urgentissima")

      expect(I18n.with_locale(:it) { priority.display_label }).to eq("Urgentissima")
    end
  end
end
