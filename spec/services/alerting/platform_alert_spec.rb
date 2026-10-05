# frozen_string_literal: true

require "rails_helper"

# CYRA-875 — alerts about CloseYourIt's own services reach only the gods, once per god.
RSpec.describe Alerting::PlatformAlert do
  let(:customer) { create(:organization) }
  let(:customer_member) { create(:account).tap { |a| create(:membership, account: a, organization: customer, role: :owner) } }

  describe ".event_type?" do
    it "covers exactly the four internal service alerts" do
      expect(%w[embedding_down ai_unavailable ai_available cache_unavailable]).to all(satisfy { |e| described_class.event_type?(e) })
      expect(described_class.event_type?("server_ingest_rejected")).to be(false)
      expect(described_class.event_type?("uptime_down")).to be(false)
    end
  end

  describe ".notify" do
    it "enqueues one evaluation per god, in the organization of the god's first membership" do
      customer_member
      home = create(:organization)
      god = create(:account, god: true)
      create(:membership, account: god, organization: home, role: :owner, created_at: 2.days.ago)
      create(:membership, account: god, organization: customer, role: :member, created_at: 1.day.ago)

      expect { described_class.notify(event_type: "ai_available", value: nil) }
        .to have_enqueued_job(Alerting::EvaluateJob).exactly(:once)
        .with(hash_including(event_type: "ai_available", organization_id: home.id, subject_id: home.id))
    end

    it "installs the platform rules in the god's organization when they are missing (fresh install)" do
      home = create(:organization)
      create(:membership, account: create(:account, god: true), organization: home)
      Alerting::Rule.where(organization: home).delete_all

      2.times { described_class.notify(event_type: "cache_unavailable", value: "locked") }

      rules = Alerting::Rule.where(organization: home)
      expect(rules.map(&:event_type)).to match_array(%w[embedding_down ai_unavailable ai_available cache_unavailable])
      expect(rules.find_by(event_type: :ai_unavailable).throttle_seconds).to eq(3600)
    end

    it "enqueues nothing when there is no god" do
      customer_member

      expect { described_class.notify(event_type: "ai_unavailable", value: "R503") }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe ".recipients" do
    it "returns only the gods whose first membership is this organization" do
      god = create(:account, god: true)
      create(:membership, account: god, organization: customer, role: :member)

      customer_member
      expect(described_class.recipients(customer)).to contain_exactly(god)
    end

    it "skips a god who belongs here but whose home is another organization, so no god gets it twice" do
      home = create(:organization)
      god = create(:account, god: true)
      create(:membership, account: god, organization: home, created_at: 2.days.ago)
      create(:membership, account: god, organization: customer, created_at: 1.day.ago)

      expect(described_class.recipients(customer)).to be_empty
      expect(described_class.recipients(home)).to contain_exactly(god)
    end
  end
end
