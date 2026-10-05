# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ReviewSchedule do
  it "dà sei mesi a una decisione" do
    adesso = Time.zone.parse("2026-09-03 10:00")

    expect(described_class.next_for(kind: :decision, from: adesso)).to eq(adesso + 180.days)
  end

  it "dà un anno a una guida" do
    adesso = Time.zone.parse("2026-09-03 10:00")

    expect(described_class.next_for(kind: :guide, from: adesso)).to eq(adesso + 365.days)
  end

  # Scenario 3 del ticket: un appunto non invecchia, e non deve intasare la coda.
  it "non dà nessuna scadenza a una nota" do
    expect(described_class.next_for(kind: :note)).to be_nil
  end

  it "non dà nessuna scadenza a un tipo che non conosce" do
    expect(described_class.next_for(kind: "inesistente")).to be_nil
  end

  it "accetta il tipo come simbolo o come stringa" do
    adesso = Time.zone.parse("2026-09-03 10:00")

    expect(described_class.next_for(kind: "decision", from: adesso))
      .to eq(described_class.next_for(kind: :decision, from: adesso))
  end

  it "elenca solo i tipi che scadono" do
    expect(described_class.expiring_kinds).to contain_exactly("decision", "guide")
  end
end
