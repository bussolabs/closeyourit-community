# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::WebVitals::Record do
  let(:project) { create(:project) }

  def misura(over = {})
    { "event_id" => SecureRandom.uuid, "metric" => "lcp", "value" => 2_400,
      "hostname" => "acme.example", "path" => "/", "occurred_at" => Time.current.iso8601 }
      .merge(over.stringify_keys)
  end

  def record_outcome(payload) = described_class.call(project:, payload:, context: { "device_type" => "mobile" })

  it "scrive il batch e riporta quante righe sono entrate" do
    expect(record_outcome([ misura, misura(metric: "cls", value: 0.04) ]).value).to eq(2)
    expect(Analytics::WebVital.count).to eq(2)
  end

  it "un batch senza niente di buono non scrive e non solleva" do
    expect(record_outcome([]).value).to be_zero
    expect(record_outcome([ "spazzatura", { "metric" => "inventata" } ]).value).to be_zero
    expect(Analytics::WebVital.count).to be_zero
  end

  describe ".acceptable?" do
    it "accetta solo un oggetto con metrica nota, valore nei limiti e indirizzo" do
      expect(described_class).to be_acceptable(misura)
      expect(described_class).not_to be_acceptable("una stringa")
      expect(described_class).not_to be_acceptable(nil)
      expect(described_class).not_to be_acceptable(misura(metric: "inventata"))
      expect(described_class).not_to be_acceptable(misura(value: "non un numero"))
      expect(described_class).not_to be_acceptable(misura(path: ""))
    end
  end

  # Il client può riprovare senza raddoppiare i numeri: un percentile calcolato su misure duplicate
  # racconterebbe un sito diverso da quello vero.
  it "lo stesso event_id non entra due volte" do
    identica = misura
    record_outcome([ identica ])
    record_outcome([ identica ])

    expect(Analytics::WebVital.count).to eq(1)
  end

  it "porta con sé i fatti anonimi del visitatore, e nient'altro" do
    record_outcome([ misura ])

    riga = Analytics::WebVital.last
    expect(riga.device_type).to eq("mobile")
    expect(riga.attributes.keys).not_to include("visitor_hash")
  end
end
