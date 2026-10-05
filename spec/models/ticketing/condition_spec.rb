require "rails_helper"

RSpec.describe Ticketing::Condition, type: :model do
  describe "factory" do
    it "produce una condizione valida" do
      expect(build(:ticketing_condition)).to be_valid
    end
  end

  describe "associazioni" do
    it "appartiene a un ticket" do
      expect(build(:ticketing_condition, ticket: nil)).not_to be_valid
    end
  end

  describe "validazioni" do
    it "richiede text (né nil né soli spazi)" do
      expect(build(:ticketing_condition, text: nil)).not_to be_valid
      expect(build(:ticketing_condition, text: "   ")).not_to be_valid
    end
  end

  describe "normalizzazione" do
    it "strippa il testo" do
      condition = create(:ticketing_condition, text: "  la mail parte  ")
      expect(condition.text).to eq("la mail parte")
    end

    it "mette gli accenti mancanti" do
      condition = create(:ticketing_condition, text: "la mail e' partita perche il job e' finito")

      expect(condition.text).to eq("la mail è partita perché il job è finito")
    end
  end

  describe ".ordered" do
    it "ordina per position" do
      ticket = create(:ticket, with_default_body: false, description: "x")
      second = ticket.conditions.create!(position: 1, text: "b")
      first  = ticket.conditions.create!(position: 0, text: "a")
      expect(Ticketing::Condition.where(ticket: ticket).ordered.to_a).to eq([ first, second ])
    end
  end
end
