# frozen_string_literal: true

require "rails_helper"

# CYRA-354 — i blocchi del grafico del volume. Le prove stanno sull'aritmetica della finestra, che è
# dove si sbaglia: un intervallo rovesciato o largo zero non deve produrre una pagina rotta.
RSpec.describe Logs::VolumeBuckets do
  let(:project) { create(:project) }
  let(:scope) { Logs::Entry.where(project_id: project.id) }
  let(:to) { Time.current }
  let(:from) { to - 24.hours }

  def entry(occurred_at, level: :info)
    create(:log_entry, project:, level:, occurred_at:)
  end

  it "restituisce sempre lo stesso numero di blocchi, anche senza messaggi" do
    risultato = described_class.call(scope:, from:, to:)

    expect(risultato.size).to eq(described_class::BUCKETS)
    expect(risultato.sum(&:count)).to be_zero
  end

  it "conta i messaggi nel blocco della loro ora" do
    entry(to - 2.hours)

    risultato = described_class.call(scope:, from:, to:)

    expect(risultato.sum(&:count)).to eq(1)
  end

  it "distingue quanti sono allarmanti" do
    allow_n_plus_one do
      entry(to - 1.hour, level: :error)
      entry(to - 1.hour, level: :info)
    end

    risultato = described_class.call(scope:, from:, to:)

    expect(risultato.sum(&:count)).to eq(2)
    expect(risultato.sum(&:alarming)).to eq(1)
  end

  it "lascia fuori quello che sta oltre la finestra" do
    entry(to - 40.hours)

    expect(described_class.call(scope:, from:, to:).sum(&:count)).to be_zero
  end

  # Una finestra larga zero (o rovesciata) non è un grafico: meglio niente che una divisione per zero.
  it "una finestra vuota non produce blocchi" do
    expect(described_class.call(scope:, from: to, to: to)).to be_empty
    expect(described_class.call(scope:, from: to, to: to - 1.hour)).to be_empty
  end

  # Finestra cortissima: l'ampiezza di un blocco non può scendere sotto il secondo.
  it "una finestra di pochi secondi resta disegnabile" do
    risultato = described_class.call(scope:, from: to - 10.seconds, to: to)

    expect(risultato.size).to eq(described_class::BUCKETS)
  end
end
