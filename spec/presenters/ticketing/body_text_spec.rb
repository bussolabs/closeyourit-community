# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::BodyText do
  let(:ticket) { create(:ticket, with_default_body: false, description: "x") }

  describe ".scenarios" do
    it "rende ogni scenario con header numerato e i soli step presenti" do
      ticket.scenarios.create!(position: 0, title: "Happy", step_given: "loggato", step_when: "compra", step_then: "ok")
      ticket.scenarios.create!(position: 1, step_given: "ospite", step_when: "compra", step_then: "500", step_expected: "ok")

      expect(described_class.scenarios(ticket.scenarios.ordered)).to eq(<<~TEXT.strip)
        Scenario 1: Happy
        Given loggato
        When compra
        Then ok

        Scenario 2
        Given ospite
        When compra
        Then 500
        Expected ok
      TEXT
    end

    it "è vuoto senza scenari" do
      expect(described_class.scenarios([])).to eq("")
    end
  end

  describe ".conditions" do
    it "rende le righe DoD come bullet" do
      ticket.conditions.create!(position: 0, text: "arriva la mail")
      ticket.conditions.create!(position: 1, text: "ordine nello storico")

      expect(described_class.conditions(ticket.conditions.ordered))
        .to eq("- arriva la mail\n- ordine nello storico")
    end

    it "è vuoto senza condizioni" do
      expect(described_class.conditions([])).to eq("")
    end
  end
end
