require "rails_helper"

RSpec.describe Ticketing::Scenario, type: :model do
  describe "factory" do
    it "produce uno scenario valido" do
      expect(build(:ticketing_scenario)).to be_valid
    end
  end

  describe "associazioni" do
    it "appartiene a un ticket" do
      expect(build(:ticketing_scenario, ticket: nil)).not_to be_valid
    end
  end

  describe "validazioni" do
    it "richiede almeno uno step (il solo titolo non basta)" do
      scenario = build(
        :ticketing_scenario,
        title: "solo titolo", step_given: nil, step_when: nil, step_then: nil, step_expected: nil,
      )
      expect(scenario).not_to be_valid
      expect(scenario.errors[:base]).to be_present
    end

    it "basta un solo step a renderlo valido" do
      Ticketing::Scenario::STEP_FIELDS.each do |field|
        scenario = build(
          :ticketing_scenario,
          step_given: nil, step_when: nil, step_then: nil, step_expected: nil, field => "x",
        )
        expect(scenario).to be_valid, "#{field} da solo dovrebbe bastare"
      end
    end
  end

  describe "normalizzazione" do
    it "strippa titolo e i 4 step" do
      scenario = create(
        :ticketing_scenario,
        title: "  Happy  ", step_given: "  a  ", step_when: "  b  ", step_then: "  c  ", step_expected: "  d  ",
      )
      expect(scenario.title).to eq("Happy")
      expect(scenario.step_given).to eq("a")
      expect(scenario.step_when).to eq("b")
      expect(scenario.step_then).to eq("c")
      expect(scenario.step_expected).to eq("d")
    end

    it "mette gli accenti mancanti negli step" do
      scenario = create(
        :ticketing_scenario,
        title: "Notifica gia inviata", step_given: "un utente gia registrato",
        step_when: "la coda e' vuota", step_then: "non succede piu' niente",
        step_expected: "la notifica e' rimandata",
      )

      expect(scenario.title).to eq("Notifica già inviata")
      expect(scenario.step_given).to eq("un utente già registrato")
      expect(scenario.step_when).to eq("la coda è vuota")
      expect(scenario.step_then).to eq("non succede più niente")
      expect(scenario.step_expected).to eq("la notifica è rimandata")
    end

    it "ha il titolo opzionale" do
      expect(build(:ticketing_scenario, title: nil)).to be_valid
    end
  end

  describe ".ordered" do
    it "ordina per position" do
      ticket = create(:ticket, with_default_body: false, description: "x")
      second = ticket.scenarios.create!(position: 1, step_given: "b")
      first  = ticket.scenarios.create!(position: 0, step_given: "a")
      expect(Ticketing::Scenario.where(ticket: ticket).ordered.to_a).to eq([ first, second ])
    end
  end

  describe "#steps?" do
    it "true se almeno uno step presente, false se tutti blank" do
      expect(build(:ticketing_scenario).steps?).to be(true)
      empty = build(:ticketing_scenario, step_given: nil, step_when: nil, step_then: nil, step_expected: nil)
      expect(empty.steps?).to be(false)
    end
  end
end
