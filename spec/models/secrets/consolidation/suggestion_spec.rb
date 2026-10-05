# frozen_string_literal: true

require "rails_helper"

# La proposta è persistita perché «non proporre più» deve restare una decisione. Da qui l'identità:
# una sola proposta per [organizzazione, ambiente, valore] — una seconda cancellerebbe la decisione
# presa sulla prima.
RSpec.describe Secrets::Consolidation::Suggestion do
  let(:organization) { create(:organization) }
  let(:environment) { create(:environment, organization:) }

  def build_suggestion(**attributes)
    described_class.new({ organization:, environment:, value_fingerprint: "a" * 64,
                          suggested_name: "API_KEY", projects_count: 2,
                          first_seen_at: Time.current, last_seen_at: Time.current }.merge(attributes))
  end

  it "nasce aperta" do
    expect(build_suggestion).to be_status_open
  end

  it "non ammette due proposte per lo stesso valore nello stesso ambiente" do
    build_suggestion.save!

    doppia = build_suggestion

    expect(doppia).not_to be_valid
    expect(doppia.errors[:value_fingerprint]).to be_present
  end

  it "ammette lo stesso valore in ambienti diversi: sono due proposte diverse" do
    build_suggestion.save!

    expect(build_suggestion(environment: create(:environment, organization:))).to be_valid
  end

  it "rifiuta un ambiente di un'altra organizzazione" do
    estraneo = create(:environment, organization: create(:organization))

    expect(build_suggestion(environment: estraneo)).not_to be_valid
  end

  it "ordina le proposte che toccano più progetti per prime, poi la più vecchia" do
    poche = build_suggestion(projects_count: 2, first_seen_at: 1.day.ago).tap(&:save!)
    molte = build_suggestion(value_fingerprint: "b" * 64, projects_count: 5).tap(&:save!)
    vecchia = build_suggestion(value_fingerprint: "c" * 64, projects_count: 2, first_seen_at: 3.days.ago).tap(&:save!)

    expect(described_class.ordered.to_a).to eq([ molte, vecchia, poche ])
  end
end
