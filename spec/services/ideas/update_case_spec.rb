# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::UpdateCase, type: :service do
  let(:idea) { create(:idea) }
  let(:case_record) { create(:idea_case, idea:, title: "Vecchio", description: "vecchia") }

  it "aggiorna titolo e descrizione su idea aperta" do
    result = described_class.call(case_record:, params: { title: "Nuovo", description: "nuova" })

    expect(result).to be_ok
    expect(case_record.reload.title).to eq("Nuovo")
    expect(case_record.description).to eq("nuova")
  end

  it "titolo vuoto → R422-IDEA-005 con details, nessuna modifica" do
    result = described_class.call(case_record:, params: { title: "  ", description: "x" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-005")
    expect(result.error.details).to have_key(:title)
    expect(case_record.reload.title).to eq("Vecchio")
  end

  it "idea congelata → R422-IDEA-002, nessuna modifica" do
    idea.update!(status: :archived)

    result = described_class.call(case_record:, params: { title: "Nuovo" })
    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-002")
    expect(case_record.reload.title).to eq("Vecchio")
  end
end
