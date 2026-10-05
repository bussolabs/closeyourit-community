# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::UnlinkIdeas, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:idea) { create(:idea, organization:, project:) }
  let(:other) { create(:idea, organization:, project:) }

  it "toglie il collegamento anche partendo dal lato che non l'ha scritto" do
    create(:idea_link, source: other, target: idea)

    expect { described_class.call(idea:, other_id: other.id) }.to change(Ideas::Link, :count).by(-1)
  end

  it "coppia non collegata → 404 R404-IDEA-002" do
    result = described_class.call(idea:, other_id: other.id)

    expect(result).to be_err
    expect(result.error.code).to eq("R404-IDEA-002")
  end
end
