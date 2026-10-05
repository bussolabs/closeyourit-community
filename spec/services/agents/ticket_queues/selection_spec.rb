# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::TicketQueues::Selection do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let!(:repository) { create(:github_repository, project:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:host) { create(:agent_host, organization:) }

  describe ".issue / .verify" do
    it "firma un token host-bound con fase e profile_digest (niente agent_id)" do
      token = described_class.issue(ticket:, host:, execution_phase: "triage")

      selection = described_class.verify(token)
      expect(selection).to include(
        version: 3,
        organization_id: organization.id,
        host_id: host.id,
        execution_phase: "triage",
        profile_digest: Agents::PhaseProfile.for("triage").digest,
        project_id: project.id,
        ticket_id: ticket.id,
        estimated_cost: nil
      )
      expect(selection).not_to have_key(:agent_id)
    end

    it "deriva la execution_phase dalla fase pronta del workflow quando non è passata" do
      token = described_class.issue(ticket:, host:)

      expect(described_class.verify(token)).to include(execution_phase: "triage")
    end

    it "rifiuta (nil) un token di versione precedente (v2)" do
      legacy = Rails.application.message_verifier(:agent_ticket_queue_selection).generate(
        { version: 2, organization_id: organization.id, agent_id: SecureRandom.uuid, project_id: project.id,
          ticket_id: ticket.id, estimated_cost: nil,
          candidate_version: described_class.candidate_version(ticket),
          repository_fingerprint: described_class.repository_fingerprint(repository) },
        purpose: "agent-ticket-queue-selection"
      )

      expect(described_class.verify(legacy)).to be_nil
    end

    it "solleva su fase sconosciuta" do
      expect { described_class.issue(ticket:, host:, execution_phase: "closer_unknown") }
        .to raise_error(ArgumentError)
    end

    it "solleva su host di un'altra organizzazione" do
      foreign_host = create(:agent_host)

      expect { described_class.issue(ticket:, host: foreign_host, execution_phase: "triage") }
        .to raise_error(ArgumentError)
    end

    it "solleva su ticket senza repository" do
      repository.destroy!

      expect { described_class.issue(ticket: ticket.reload, host:, execution_phase: "triage") }
        .to raise_error(ArgumentError)
    end
  end

  describe ".valid_payload?" do
    let(:base) do
      {
        organization_id: organization.id, host_id: host.id, execution_phase: "triage",
        profile_digest: Agents::PhaseProfile.for("triage").digest, project_id: project.id,
        ticket_id: ticket.id, estimated_cost: nil,
        candidate_version: described_class.candidate_version(ticket),
        repository_fingerprint: described_class.repository_fingerprint(repository)
      }
    end

    it "accetta un payload host-first completo" do
      expect(described_class.valid_payload?(base)).to be true
    end

    it "rifiuta un payload senza le chiavi host-first richieste" do
      %i[host_id execution_phase profile_digest project_id ticket_id candidate_version repository_fingerprint].each do |key|
        expect(described_class.valid_payload?(base.merge(key => ""))).to be(false), "atteso false con #{key} vuota"
      end
    end

    it "rifiuta una execution_phase sconosciuta" do
      expect(described_class.valid_payload?(base.merge(execution_phase: "nope"))).to be false
    end

    it "rifiuta un profile_digest di lunghezza diversa da 64" do
      expect(described_class.valid_payload?(base.merge(profile_digest: "abc"))).to be false
    end

    it "rifiuta nil" do
      expect(described_class.valid_payload?(nil)).to be false
    end
  end
end
