# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::LinkIdeas, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:idea) { create(:idea, organization:, project:) }
  let(:other) { create(:idea, organization:, project:) }

  it "collega due idee alla pari" do
    result = described_class.call(idea:, target_id: other.id)

    expect(result).to be_ok
    expect(result.value).to be_kind_related
    expect(idea.reload.related_ideas).to eq([ other ])
  end

  it "collega come evoluzione (l'idea evolve la target)" do
    result = described_class.call(idea:, target_id: other.id, kind: :evolution)

    expect(result).to be_ok
    expect(idea.reload.parent).to eq(other)
    expect(other.reload.evolutions).to eq([ idea ])
  end

  it "target di un altro progetto → 404 R404-IDEA-002 (anti-BOLA)" do
    foreign = create(:idea, organization:)

    result = described_class.call(idea:, target_id: foreign.id)

    expect(result).to be_err
    expect(result.error.code).to eq("R404-IDEA-002")
    expect(result.error.status).to eq(:not_found)
  end

  it "coppia già collegata → 422 R422-IDEA-006 con details" do
    create(:idea_link, source: other, target: idea)

    result = described_class.call(idea:, target_id: other.id)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-006")
    expect(result.error.details).to have_key(:target)
  end

  it "kind sconosciuto → 422 R422-IDEA-006, nessuna riga" do
    expect do
      result = described_class.call(idea:, target_id: other.id, kind: "cugina")
      expect(result.error.code).to eq("R422-IDEA-006")
    end.not_to change(Ideas::Link, :count)
  end
end
