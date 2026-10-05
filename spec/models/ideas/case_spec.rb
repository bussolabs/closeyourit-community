# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::Case, type: :model do
  let(:idea) { create(:idea) }

  describe "validazioni" do
    it "è valido con idea e titolo" do
      expect(build(:idea_case, idea: idea)).to be_valid
    end

    it "rifiuta il titolo mancante (anche solo spazi, via normalizes)" do
      case_record = build(:idea_case, idea: idea, title: "   ")
      expect(case_record).not_to be_valid
      expect(case_record.errors[:title]).to be_present
    end

    it "accetta la descrizione mancante (opzionale)" do
      expect(build(:idea_case, idea: idea, description: "")).to be_valid
    end

    it "normalizza titolo e descrizione (strip)" do
      case_record = build(:idea_case, idea: idea, title: "  Onboarding  ", description: "  esempio  ")
      case_record.validate
      expect(case_record.title).to eq("Onboarding")
      expect(case_record.description).to eq("esempio")
    end
  end

  describe "relazione con l'idea" do
    it "appartiene all'idea e ne incrementa cases_count" do
      case_record = nil
      expect { case_record = create(:idea_case, idea: idea) }
        .to change { idea.reload.cases_count }.from(0).to(1)
      expect(case_record.idea).to eq(idea)
    end

    it "richiede un'idea" do
      case_record = build(:idea_case, idea: nil)
      expect(case_record).not_to be_valid
      expect(case_record.errors[:idea]).to be_present
    end
  end
end
