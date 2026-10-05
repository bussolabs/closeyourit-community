# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::AddCase, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:idea) { create(:idea, organization:, project:) }

  it "aggiunge il case a un'idea aperta e aggiorna il contatore" do
    result = described_class.call(idea:, params: { title: "Onboarding", description: "Nuovo cliente" })

    expect(result).to be_ok
    expect(result.value).to be_persisted
    expect(idea.reload.cases_count).to eq(1)
  end

  it "accetta la descrizione mancante" do
    result = described_class.call(idea:, params: { title: "Solo titolo", description: "" })

    expect(result).to be_ok
  end

  it "titolo vuoto → R422-IDEA-005 con details" do
    result = described_class.call(idea:, params: { title: "  ", description: "x" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-005")
    expect(result.error.details).to have_key(:title)
  end

  it "idea archiviata (congelata) → R422-IDEA-002, nessun case" do
    frozen = create(:idea, :archived, organization:, project:)

    expect do
      result = described_class.call(idea: frozen, params: { title: "tardi" })
      expect(result).to be_err
      expect(result.error.code).to eq("R422-IDEA-002")
    end.not_to change(Ideas::Case, :count)
  end

  it "idea convertita (congelata) → R422-IDEA-002" do
    frozen = create(:idea, :converted, organization:, project:)

    result = described_class.call(idea: frozen, params: { title: "tardi" })
    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-002")
  end
end
