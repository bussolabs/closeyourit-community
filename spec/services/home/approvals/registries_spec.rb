# frozen_string_literal: true

require "rails_helper"

# CYRA-801 — i tre servizi della coda approvazioni smistavano componendo a runtime il nome del
# metodo da chiamare: cercare «chi chiama clarification_card» non trovava nessuno, e l'elenco dei
# casi gestiti non era scritto da nessuna parte. Ora sono tre registri espliciti, e questa è la
# rete che li tiene allineati al vocabolario: un tipo di card nuovo dimenticato in uno dei tre
# cade qui invece che davanti a chi apre la pagina.
RSpec.describe "I registri della coda approvazioni", type: :service do
  # Il vocabolario dei tipi di card vive in un posto solo: Detail::KINDS. I registri lo seguono, non
  # ne aggiungono un secondo.
  let(:kinds) { Home::Approvals::Detail::KINDS }

  # I metodi di smistamento sono privati: il registro è l'unica porta.
  def privato?(klass, metodo) = klass.private_instance_methods(false).include?(metodo)

  describe Home::Approvals::Detail do
    it "nomina esattamente i tipi di card del vocabolario" do
      expect(described_class::CARD_BUILDERS.keys).to match_array(kinds)
    end

    it "manda ogni tipo a un costruttore che esiste e resta privato" do
      described_class::CARD_BUILDERS.each_value do |builder|
        expect(privato?(described_class, builder)).to be(true), "#{builder} non è un metodo privato"
      end
    end

    it "su un tipo fuori registro solleva invece di provare un metodo a caso" do
      expect { described_class::CARD_BUILDERS.fetch("pippo") }.to raise_error(KeyError)
    end
  end

  describe Home::Approvals::Settled do
    it "sa dire com'è finita per esattamente gli stessi tipi di card" do
      expect(described_class::OUTCOME_BUILDERS.keys).to match_array(kinds)
    end

    it "manda ogni tipo a un lettore che esiste e resta privato" do
      described_class::OUTCOME_BUILDERS.each_value do |builder|
        expect(privato?(described_class, builder)).to be(true), "#{builder} non è un metodo privato"
      end
    end

    it "su un tipo fuori registro solleva invece di provare un metodo a caso" do
      expect { described_class::OUTCOME_BUILDERS.fetch("pippo") }.to raise_error(KeyError)
    end
  end

  describe Home::Approvals::Decide do
    it "nomina esattamente le decisioni che accetta" do
      expect(described_class::DECISION_HANDLERS.keys).to match_array(described_class::DECISIONS)
    end

    it "manda ogni decisione a un esecutore che esiste e resta privato" do
      described_class::DECISION_HANDLERS.each_value do |handler|
        expect(privato?(described_class, handler)).to be(true), "#{handler} non è un metodo privato"
      end
    end

    it "su una decisione fuori registro solleva invece di provare un metodo a caso" do
      expect { described_class::DECISION_HANDLERS.fetch(:pippo) }.to raise_error(KeyError)
    end
  end

  # Scenario 2 del ticket: il nome del metodo non torna a comporsi da sé. Una `send` con nome
  # interpolato rimette i casi fuori dalla portata di chi cerca nel codice, ed è il guasto che
  # questo ticket ha chiuso.
  it "nessuno dei tre servizi ricompone il nome del metodo a runtime" do
    sorgenti = %w[decide.rb detail.rb settled.rb].to_h do |file|
      [ file, Rails.root.join("app/services/home/approvals", file).read ]
    end
    colpevoli = sorgenti.select { |_file, codice| codice.match?(/\bsend\(:"[^"]*#[{]/) }

    expect(colpevoli.keys).to be_empty,
      "chiamano una funzione costruendone il nome: #{colpevoli.keys.join(', ')}"
  end
end
