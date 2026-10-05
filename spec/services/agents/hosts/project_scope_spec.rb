# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Hosts::ProjectScope do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def service_account_seeing(project_ids, handle:)
    Accounts::Service::Create.call(organization:, name: "Host SA", handle:, project_ids:).value
  end

  it "consente quando il service account dell'host vede il progetto" do
    host = create(:agent_host, organization:, service_account: service_account_seeing([ project.id ], handle: "host_sa_ok"))

    expect(described_class.new(host:).allows?(project)).to be(true)
  end

  it "nega (fail-closed) quando il service account dell'host non vede il progetto" do
    host = create(:agent_host, organization:, service_account: service_account_seeing([], handle: "host_sa_blind"))

    expect(described_class.new(host:).allows?(project)).to be(false)
  end

  it "nega (fail-closed) quando l'host non ha alcun service account" do
    host = create(:agent_host, organization:, service_account: nil)

    expect(described_class.new(host:).allows?(project)).to be(false)
  end

  it "nega (fail-closed) quando l'host è nil" do
    expect(described_class.new(host: nil).allows?(project)).to be(false)
  end

  describe "#projects (insieme, usato da WorkspaceManifest)" do
    it "elenca i progetti visibili al service account dell'host" do
      host = create(:agent_host, organization:, service_account: service_account_seeing([ project.id ], handle: "host_sa_list"))

      expect(described_class.new(host:).projects).to contain_exactly(project)
    end

    it "è vuoto (mai l'intero catalogo) quando l'host non ha service account" do
      host = create(:agent_host, organization:, service_account: nil)

      expect(described_class.new(host:).projects).to be_empty
    end

    it "è vuoto quando l'host è nil" do
      expect(described_class.new(host: nil).projects).to be_empty
    end
  end

  it "nega un progetto di un'altra organizzazione (org vincolata all'host, cross-tenant chiuso)" do
    other_project = create(:project, organization: create(:organization))
    host = create(:agent_host, organization:, service_account: service_account_seeing([ project.id ], handle: "host_sa_x"))

    expect(described_class.new(host:).allows?(other_project)).to be(false)
  end

  it "deriva l'organizzazione dall'HOST, non da un agente (autorità unica host)" do
    host = create(:agent_host, organization:, service_account: service_account_seeing([ project.id ], handle: "host_sa_org"))

    # Nessun agente nella firma: la sola identità host basta a decidere lo scope.
    expect(described_class.new(host:).allows?(project)).to be(true)
  end
end
