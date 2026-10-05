# frozen_string_literal: true

require "rails_helper"

# Destinatari dell'allarme agents_stalled (org-scoped, CYRA-212): owner + membri con agents.view/manage.
RSpec.describe Alerting::Recipients do
  describe ".for_agents" do
    let(:org) { create(:organization) }

    def member!(account, role = :member) = create(:membership, account: account, organization: org, role: role)

    def role_with(name, *keys)
      role = create(:role, organization: org, name: name)
      keys.each { |k| create(:role_permission, role: role, permission_key: k) }
      role
    end

    it "include gli owner sempre" do
      owner = create(:account)
      member!(owner, :owner)

      expect(described_class.for_agents(organization: org)).to include(owner)
    end

    it "include il membro con agents.view via ruolo, esclude chi non ha il permesso" do
      viewer = create(:account)
      member!(viewer)
      create(:account_role, account: viewer, organization: org, role: role_with("Ops", "agents.view"))
      blind = create(:account)
      member!(blind)

      recipients = described_class.for_agents(organization: org)

      expect(recipients).to include(viewer)
      expect(recipients).not_to include(blind)
    end

    it "include il membro con solo agents.manage (manage implica view)" do
      manager = create(:account)
      member!(manager)
      create(:account_role, account: manager, organization: org, role: role_with("Automation admin", "agents.manage"))

      expect(described_class.for_agents(organization: org)).to include(manager)
    end

    it "esclude i membri di altre organization" do
      other = create(:account)
      create(:membership, account: other, organization: create(:organization), role: :owner)

      expect(described_class.for_agents(organization: org)).not_to include(other)
    end
  end
end
