# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::EmbeddingText do
  describe ".call" do
    it "compone titolo, tipo, descrizione e scenari BDD con etichette fisse" do
      ticket = build(:ticket, with_default_body: false, title: "Crash al login", description: "Succede sempre")
      ticket.scenarios.build(step_given: "utente registrato", step_when: "fa login",
                             step_then: "500", step_expected: "dashboard")

      text = described_class.call(ticket: ticket)

      expect(text).to eq(<<~TEXT.strip)
        Titolo: Crash al login
        Tipo: bug
        Descrizione: Succede sempre
        Scenari:
        Scenario 1
        Given utente registrato
        When fa login
        Then 500
        Expected dashboard
      TEXT
    end

    it "salta i campi vuoti (story senza scenari)" do
      ticket = build(:ticket, :story, title: "Export CSV", description: "Serve export")

      expect(described_class.call(ticket: ticket)).to eq("Titolo: Export CSV\nTipo: story\nDescrizione: Serve export")
    end

    it "include l'analisi tecnica quando presente" do
      ticket = build(:ticket, :story, title: "X", description: "d", technical_analysis: "N+1 su Orders#index")

      expect(described_class.call(ticket: ticket)).to include("Analisi tecnica: N+1 su Orders#index")
    end
  end

  describe ".checksum" do
    it "è stabile a parità di contenuto e cambia col testo" do
      ticket = build(:ticket, title: "A")

      first = described_class.checksum(ticket: ticket)
      expect(described_class.checksum(ticket: ticket)).to eq(first)

      ticket.title = "B"
      expect(described_class.checksum(ticket: ticket)).not_to eq(first)
    end

    it "cambia al bump di EMBEDDING_VERSION (leva di re-embed globale)" do
      ticket = build(:ticket, title: "A")
      before = described_class.checksum(ticket: ticket)

      stub_const("Ai::Constants::EMBEDDING_VERSION", "test-v2")

      expect(described_class.checksum(ticket: ticket)).not_to eq(before)
    end
  end
end
