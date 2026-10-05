# frozen_string_literal: true

require "rails_helper"

# Il registro dei FILE segreti di progetto. Due cose lo distinguono dagli altri audit: ricava da solo
# il contesto dall'asset (il caso normale) e sa scrivere anche quando l'asset NON esiste — il rifiuto
# sul caricamento avviene prima che il file ci sia, e senza contesto quel tentativo sarebbe una riga
# orfana, cioè inutile.
RSpec.describe Secrets::Assets::RecordEvent do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) do
    create(:environment, organization:, code: "production").tap { |env| project.environments << env }
  end
  let(:actor) { create(:account) }
  let(:asset) do
    Secrets::Asset.create!(organization:, project:, environment:, name: "AuthKey", asset_type: "p8")
  end

  it "ricava organizzazione, progetto e ambiente dall'asset" do
    event = described_class.call(action: "downloaded", actor:, asset:, metadata: { version: 2 })

    expect(event).to be_persisted
    expect(event).to have_attributes(action: "downloaded", asset:, organization:, project:, environment:,
                                     actor:)
    expect(event.metadata).to eq({ "version" => 2 })
  end

  # CYRA-666: il rifiuto sul caricamento arriva prima che il file esista.
  it "senza asset scrive comunque il tentativo, col contesto passato a mano" do
    event = described_class.call(action: "denied", actor:, project:, environment:, organization:)

    expect(event).to be_persisted
    expect(event.asset).to be_nil
    expect(event).to have_attributes(organization:, project:, environment:, actor:)
  end

  it "senza organizzazione esplicita la prende dal progetto" do
    event = described_class.call(action: "denied", actor:, project:)

    expect(event.organization).to eq(organization)
  end

  it "un file condiviso non ha progetto e l'evento nemmeno" do
    condiviso = Secrets::Asset.create!(organization:, name: "Shared", asset_type: "p12")

    event = described_class.call(action: "uploaded", actor:, asset: condiviso)

    expect(event.project).to be_nil
    expect(event.organization).to eq(organization)
  end

  it "è fire-and-forget: un'azione che non esiste non solleva e lascia detto perché" do
    allow(Rails.logger).to receive(:error)

    expect { described_class.call(action: "telepatia", actor:, asset:) }
      .not_to change(Secrets::AssetEvent, :count)
    expect(Rails.logger).to have_received(:error).with(/secret_asset_audit_failed/)
  end

  it "un guasto del database non ferma l'operazione che stava registrando" do
    allow(Secrets::AssetEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "db giù")
    allow(Rails.logger).to receive(:error)

    expect { described_class.call(action: "downloaded", actor:, asset:) }.not_to raise_error
  end
end
