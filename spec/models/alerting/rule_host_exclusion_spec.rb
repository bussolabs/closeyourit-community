# frozen_string_literal: true

require "rails_helper"

# CYRA-519 — «questa regola, su questa macchina, non deve suonare». Il confine di tenant sta qui:
# silenziare la regola di un'organizzazione su una macchina di un'altra non è una svista da
# correggere a valle, è una riga che non deve esistere.
RSpec.describe Alerting::RuleHostExclusion do
  let(:organization) { create(:organization) }
  let(:host) { create(:server_host, organization:) }
  let(:rule) { create(:alerting_rule, organization:, event_type: :server_down) }

  it "regola e macchina della stessa organizzazione: valida" do
    expect(described_class.new(rule:, host:)).to be_valid
  end

  it "macchina di un'altra organizzazione: rifiutata" do
    estranea = create(:server_host, organization: create(:organization))

    exclusion = described_class.new(rule:, host: estranea)

    expect(exclusion).not_to be_valid
    expect(exclusion.errors[:host]).to be_present
  end

  it "senza regola o senza macchina non si pronuncia sul tenant" do
    expect(described_class.new(rule: nil, host:)).not_to be_valid
    expect(described_class.new(rule:, host: nil)).not_to be_valid
  end

  it "la stessa coppia non si ripete" do
    described_class.create!(rule:, host:)

    expect(described_class.new(rule:, host:)).not_to be_valid
  end
end
