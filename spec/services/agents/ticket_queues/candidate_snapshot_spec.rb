# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::TicketQueues::CandidateSnapshot do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let!(:repository) { create(:github_repository, project:) }
  let(:ticket) { create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true) }
  let(:host) do
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA", project_ids: [ project.id ]).value
    create(:agent_host, organization:, service_account:)
  end
  let(:snapshot) { described_class.new(organization:, host:) }
  let(:selection) do
    {
      organization_id: organization.id, host_id: host.id, execution_phase: "triage",
      profile_digest: Agents::PhaseProfile.for("triage").digest, project_id: project.id, ticket_id: ticket.id,
      candidate_version: Agents::TicketQueues::Selection.candidate_version(ticket),
      repository_fingerprint: Agents::TicketQueues::Selection.repository_fingerprint(repository)
    }
  end

  describe "#eligible?" do
    it "è eleggibile quando fase firmata, profile_digest, scope host e versioni combaciano" do
      expect(snapshot.eligible?(snapshot.load(selection), selection)).to be true
    end

    it "è stale se il workflow è avanzato oltre la fase firmata" do
      ticket.agent_workflow.update!(triaged_at: Time.current) # ready diventa planner, la firma è triage

      expect(snapshot.eligible?(snapshot.load(selection), selection)).to be false
    end

    it "fallisce chiuso sul drift del profilo di fase (digest diverso)" do
      drifted = selection.merge(profile_digest: "0" * 64)

      expect(snapshot.eligible?(snapshot.load(selection), drifted)).to be false
    end

    it "è stale se il service account dell'host non vede più il progetto" do
      Connections::ProjectMembership.where(account: host.service_account, project:).delete_all

      expect(snapshot.eligible?(snapshot.load(selection), selection)).to be false
    end

    it "è stale se lo status del ticket è done" do
      ticket.update!(status: create(:ticket_status, :done, organization:))

      expect(snapshot.eligible?(snapshot.load(selection), selection)).to be false
    end

    it "è stale se candidate_version non combacia" do
      expect(snapshot.eligible?(snapshot.load(selection), selection.merge(candidate_version: "diverso"))).to be false
    end

    it "è stale se repository_fingerprint non combacia" do
      expect(snapshot.eligible?(snapshot.load(selection), selection.merge(repository_fingerprint: "diverso"))).to be false
    end

    describe "gate di eleggibilità agenti (CYRA-184)" do
      # TOCTOU reale: la selezione vale Selection::DEFAULT_TTL (5 minuti), tempo più che sufficiente
      # perché una persona blocchi il ticket dopo che il token è stato firmato.
      it "non è più eleggibile se il ticket viene bloccato dopo l'emissione della selezione" do
        signed = selection # firmata mentre il ticket era consentito
        ticket.update!(agent_eligibility: :blocked, agent_eligibility_source: :human)

        expect(snapshot.eligible?(snapshot.load(signed), signed)).to be false
      end

      it "non è più eleggibile se il ticket torna da valutare" do
        signed = selection
        ticket.update!(agent_eligibility: :pending)

        expect(snapshot.eligible?(snapshot.load(signed), signed)).to be false
      end

      # Il gate esplicito non deve poggiare su candidate_version: se un domani il serializer smettesse
      # di esporre agent_eligibility, questo test resterebbe verde solo grazie alla riga in eligible?.
      it "respinge il ticket bloccato anche quando candidate_version è ancora allineata" do
        blocked = selection.dup
        ticket.update_columns(agent_eligibility: Ticketing::Ticket.agent_eligibilities[:blocked])
        blocked[:candidate_version] = Agents::TicketQueues::Selection.candidate_version(ticket.reload)

        expect(snapshot.eligible?(snapshot.load(blocked), blocked)).to be false
      end
    end
  end

  describe "#load / #lock" do
    it "carica lo snapshot host-first (ticket/progetto/repository) senza agent" do
      context = snapshot.load(selection)

      expect(context.ticket).to eq(ticket)
      expect(context.project).to eq(project)
      expect(context.repository).to eq(repository)
      expect(context.respond_to?(:agent)).to be false
    end

    it "rilegge sotto lock lo stesso ticket host-first" do
      ActiveRecord::Base.transaction do
        expect(snapshot.lock(selection).ticket).to eq(ticket)
      end
    end
  end
end
