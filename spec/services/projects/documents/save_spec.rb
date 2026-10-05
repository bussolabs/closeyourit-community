# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Documents::Save, type: :service do
  let(:project) { create(:project) }
  let(:actor) { create(:account) }

  it "aggiorna titolo/tag e registra un evento 'updated' coi campi cambiati" do
    document = create(:document, project: project, title: "Originale")

    expect do
      result = described_class.call(document: document, attributes: { title: "Rinominato" }, actor: actor)
      expect(result).to be_ok
    end.to change(Activity::Event, :count).by(1)

    expect(document.reload.title).to eq("Rinominato")
    event = document.activity_events.chronological.last
    expect(event.action).to eq("updated")
    expect(event.data["fields"]).to include("title")
    expect(event.actor).to eq(actor)
  end

  it "NON registra eventi se non cambia nulla (niente rumore)" do
    document = create(:document, project: project, title: "Invariato")

    expect do
      described_class.call(document: document, attributes: { title: "Invariato" }, actor: actor)
    end.not_to change(Activity::Event, :count)
  end

  it "titolo vuoto → R422-DOCUMENT-002, nessun evento orfano" do
    document = create(:document, project: project)

    expect do
      result = described_class.call(document: document, attributes: { title: "" }, actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-DOCUMENT-002")
    end.not_to change(Activity::Event, :count)
  end
end
