# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::LimitPolicy, type: :model do
  describe "max_daily_cost" do
    it "rifiuta una frazione sotto la scala decimal(14,4)" do
      policy = build(:agent_limit_policy, max_daily_cost: "0.00001")

      expect(policy).to be_invalid
      expect(policy.errors.details[:max_daily_cost]).to include(a_hash_including(error: :invalid))
    end

    it "canonicalizza valori equivalenti entro quattro decimali" do
      policy = create(:agent_limit_policy, max_daily_cost: "0.50000")

      expect(policy.reload.max_daily_cost).to eq(BigDecimal("0.5000"))
    end

    it "accetta il massimo decimal(14,4)" do
      policy = build(:agent_limit_policy, max_daily_cost: "9999999999.9999")

      expect(policy).to be_valid
    end

    it "rifiuta l'overflow decimal(14,4) prima del database" do
      policy = build(:agent_limit_policy, max_daily_cost: "10000000000")

      expect(policy).to be_invalid
      expect(policy.errors[:max_daily_cost]).to be_present
    end

    it "rifiuta un valore non numerico prima del database" do
      policy = build(:agent_limit_policy, max_daily_cost: "not-a-number")

      expect(policy).to be_invalid
      expect(policy.errors.details[:max_daily_cost]).to include(a_hash_including(error: :invalid))
    end
  end

  it "rifiuta un progetto appartenente a un'altra organizzazione" do
    policy = build(
      :agent_limit_policy,
      organization: create(:organization),
      project: create(:project, organization: create(:organization))
    )

    expect(policy).to be_invalid
    expect(policy.errors.details[:project]).to include(a_hash_including(error: :invalid))
  end
end
