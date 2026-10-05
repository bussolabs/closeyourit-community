# frozen_string_literal: true

require "rails_helper"

# Gemello del registro dei file di progetto, per il vault personale. La differenza che conta: il nome
# del file finisce SEMPRE nei dati della riga, così l'attività resta leggibile anche dopo che il file
# è stato cancellato e il collegamento all'asset è caduto.
RSpec.describe Secrets::Personal::Assets::RecordEvent do
  let(:asset) { create(:personal_secret_asset, name: "id_rsa") }

  it "scrive la riga legandola all'account e all'organizzazione dell'asset" do
    event = described_class.call(action: "uploaded", asset:)

    expect(event).to be_persisted
    expect(event).to have_attributes(action: "uploaded", asset:, account: asset.account,
                                     organization: asset.organization)
  end

  it "il nome resta scritto nei dati: sopravvive alla cancellazione del file" do
    event = described_class.call(action: "downloaded", asset:, metadata: { version: 3 })

    expect(event.metadata).to eq({ "name" => "id_rsa", "version" => 3 })
  end

  it "accetta i dati con le chiavi come simboli e li scrive come testo" do
    event = described_class.call(action: "rolled_back", asset:, metadata: { from: 1, to: 3 })

    expect(event.metadata).to include("from" => 1, "to" => 3)
  end

  it "chi passa un nome nei dati non sovrascrive quello dell'asset" do
    event = described_class.call(action: "purged", asset:, metadata: { "name" => "altro" })

    expect(event.metadata["name"]).to eq("altro")
  end

  it "è fire-and-forget: un'azione che non esiste non solleva e lascia detto perché" do
    allow(Rails.logger).to receive(:error)

    expect { described_class.call(action: "telepatia", asset:) }
      .not_to change(Secrets::Personal::AssetEvent, :count)
    expect(Rails.logger).to have_received(:error).with(/personal_secret_asset_audit_failed/)
  end
end
