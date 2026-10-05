# frozen_string_literal: true

require "rails_helper"

# Destinatari degli eventi secrets_* di progetto (rotazione in scadenza, CYRA-138 Fase 4 pezzo A2, e in
# futuro altri): owner + chi VEDE il progetto e ha il permesso secrets.manage. Gemello project-scoped
# di .for_servers (che è org-scoped).
RSpec.describe Alerting::Recipients do
  describe ".for_secrets" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization: organization) }

    def member!(account, role = :member) = create(:membership, account: account, organization: organization, role: role)

    def role_with(name, *keys)
      role = create(:role, organization: organization, name: name)
      keys.each { |k| create(:role_permission, role: role, permission_key: k) }
      role
    end

    it "include l'owner sempre, anche senza assegnazioni dirette al progetto" do
      owner = create(:account)
      member!(owner, :owner)

      expect(described_class.for_secrets(project: project)).to include(owner)
    end

    it "include un membro visibile al progetto con secrets.manage via ruolo" do
      manager = create(:account)
      member!(manager)
      create(:project_membership, account: manager, project: project)
      create(:account_role, account: manager, organization: organization, role: role_with("Vault admin", "secrets.manage"))

      expect(described_class.for_secrets(project: project)).to include(manager)
    end

    it "ESCLUDE chi vede il progetto ma non ha secrets.manage" do
      viewer = create(:account)
      member!(viewer)
      create(:project_membership, account: viewer, project: project)

      expect(described_class.for_secrets(project: project)).not_to include(viewer)
    end

    it "ESCLUDE chi ha secrets.manage ma non vede il progetto (nessun link diretto/gruppo/team)" do
      account = create(:account)
      member!(account)
      create(:account_role, account: account, organization: organization, role: role_with("Vault admin", "secrets.manage"))

      expect(described_class.for_secrets(project: project)).not_to include(account)
    end

    it "esclude un membro di un'altra organizzazione (confine tenant)" do
      other_org = create(:organization)
      stranger = create(:account)
      create(:membership, account: stranger, organization: other_org, role: :owner)

      expect(described_class.for_secrets(project: project)).not_to include(stranger)
    end
  end
end
