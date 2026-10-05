# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::TicketQueues::Claim do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:host) do
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA", project_ids: [ project.id ]).value
    create(:agent_host, organization:, service_account:)
  end
  let(:service) do
    described_class.new(organization:, host:, selection_token: "token", params: {})
  end
  let(:selection) { { execution_phase: "triage", candidate_version: "digest" } }

  describe "#mark_workflow_started!" do
    it "attribuisce planner e autopilot a host + service account e incrementa lo snapshot" do
      workflow.update!(ticket_snapshot_digest: "precedente", ticket_snapshot_version: 2)

      service.send(:mark_workflow_started!, workflow, { execution_phase: "planner", candidate_version: "digest" })
      expect(workflow.reload).to have_attributes(
        planned_by_host: host, planned_by_service_account: host.service_account,
        ticket_snapshot_version: 3, ticket_snapshot_digest: "digest"
      )

      service.send(:mark_workflow_started!, workflow, { execution_phase: "autopilot", candidate_version: "digest" })
      expect(workflow.reload).to have_attributes(
        autopilot_by_host: host, autopilot_by_service_account: host.service_account, autopilot_started_at: be_present
      )
    end

    it "timbra la fase senza puntatori legacy" do
      service.send(:mark_workflow_started!, workflow, { execution_phase: "triage", candidate_version: "digest" })

      expect(workflow.reload).to have_attributes(
        triage_by_host: host, triage_by_service_account: host.service_account,
        triage_started_at: be_present
      )
    end

    it "mantiene soltanto lo snapshot per una execution_phase sconosciuta" do
      service.send(:mark_workflow_started!, workflow, { execution_phase: "unknown", candidate_version: "digest" })

      expect(workflow.reload).to have_attributes(
        ticket_snapshot_digest: "digest", triage_started_at: nil, planned_by_host: nil, autopilot_started_at: nil
      )
    end
  end

  describe "#ensure_attempt!" do
    let(:context) { Struct.new(:workflow, :ticket).new(workflow, ticket) }
    let(:claim) do
      described_class.new(organization:, host:, selection_token: "token",
                          params: { run_id: "run-1" }).tap { |c| c.instance_variable_set(:@selection, selection) }
    end

    it "crea un Attempt host-first (service account + profilo di fase)" do
      attempt = claim.send(:ensure_attempt!, context, selection)

      profile = Agents::PhaseProfile.for("triage")
      expect(attempt).to have_attributes(
        host:, service_account: host.service_account, phase: "triage", skill_key: profile.skill_key,
        runtime: profile.runtime, sandbox: profile.sandbox, permission_mode: profile.permission_mode,
        ttl: profile.ttl, status: "running"
      )
    end

    it "è idempotente sul replay (stessa host+phase+ticket+run) senza creare un secondo tentativo" do
      first = claim.send(:ensure_attempt!, context, selection)

      expect { @second = claim.send(:ensure_attempt!, context, selection) }.not_to change(Agents::Attempt, :count)
      expect(@second).to eq(first)
      expect(claim.send(:idempotent_replay?, context)).to be(true)
    end

    it "fallisce chiuso su execution_phase sconosciuta (PhaseProfile.fetch)" do
      unknown = described_class.new(organization:, host:, selection_token: "token", params: { run_id: "run-x" })
      unknown.instance_variable_set(:@selection, { execution_phase: "nope" })

      expect { unknown.send(:ensure_attempt!, context, { execution_phase: "nope" }) }.to raise_error(KeyError)
    end

    # CYRA-201: la stessa lavorazione può ritentare dopo essere stata dichiarata FERMA dal controllo
    # periodico. `find_or_create_by!` ritroverebbe quel record terminale e lo passerebbe a valle, dove
    # `Attempt#ensure_mutable` solleva ReadOnlyRecord — che `Deliver` non intercetta, quindi un 500 al
    # posto di un conflitto. Qui è invece una selezione stale.
    Agents::Attempt::TERMINAL_STATUSES.each do |terminal|
      it "ritorna nil su un tentativo già #{terminal} (selezione stale, non un record immutabile)" do
        existing = claim.send(:ensure_attempt!, context, selection)
        existing.update_columns(status: Agents::Attempt.statuses.fetch(terminal), finished_at: Time.current)

        expect { @again = claim.send(:ensure_attempt!, context, selection) }.not_to change(Agents::Attempt, :count)
        expect(@again).to be_nil
      end
    end

    it "un tentativo dichiarato ferma non blocca più i claim successivi sullo stesso ticket" do
      attempt = claim.send(:ensure_attempt!, context, selection)
      # Prima: `stale` non veniva mai assegnato, quindi l'orfano restava `running` e `idempotent_replay?`
      # lo prendeva per un tentativo in corso — bloccando ogni claim successivo.
      expect(claim.send(:idempotent_replay?, context)).to be(true)

      attempt.update_columns(status: Agents::Attempt.statuses.fetch("stale"), finished_at: Time.current)

      expect(claim.send(:idempotent_replay?, context)).to be(false)
    end
  end

  describe "#lease_params" do
    it "propaga la execution_phase firmata come lease host-first puro, senza slug agent" do
      context = Struct.new(:ticket).new(ticket)
      reservation = Struct.new(:requested_ttl_seconds).new(3600)
      claim = described_class.new(organization:, host:, selection_token: "token",
                                  params: { host_id: host.id, run_id: "run-1" })
      claim.instance_variable_set(:@selection, { execution_phase: "triage" })

      params = claim.send(:lease_params, context, reservation)

      expect(params).to include(
        execution_phase: "triage", ttl_seconds: 3600, host_id: host.id, run_id: "run-1"
      )
      expect(params).not_to have_key(:agent)
    end
  end

  describe "#capture_work_context" do
    let(:context) { Struct.new(:ticket).new(ticket) }

    it "fotografa la guidance corrente in uno snapshot attribuito al service account dell'host" do
      create(:guidance_procedure, owner: project, key: "setup", content: "Installa le dipendenze")

      expect { service.send(:capture_work_context, context) }
        .to change { ticket.reload.work_context_snapshot }.from(nil)

      snapshot = ticket.work_context_snapshot
      expect(snapshot.actor).to eq(host.service_account)
      expect(snapshot.payload.fetch("procedures").map { |procedure| procedure["key"] }).to eq(%w[setup])
    end

    it "è idempotente: claim ripetuti sullo stesso ticket non duplicano lo snapshot" do
      service.send(:capture_work_context, context)

      expect { service.send(:capture_work_context, context) }
        .not_to change(Ticketing::WorkContextSnapshot, :count)
    end
  end

  describe "flusso sotto lock (token host-bound)" do
    let(:context) { Struct.new(:project, :ticket, :workflow).new(project, ticket, workflow) }
    let(:payload) do
      { organization_id: organization.id, host_id: host.id, execution_phase: "triage",
        profile_digest: Agents::PhaseProfile.for("triage").digest }
    end
    let(:claim) do
      described_class.new(organization:, host:, selection_token: "token",
                          params: { host_id: host.id, run_id: "run", ttl_seconds: 3600 })
    end
    let(:snapshot) { instance_double(Agents::TicketQueues::CandidateSnapshot) }

    before do
      claim.instance_variable_set(:@snapshot, snapshot)
      allow(Agents::TicketQueues::Selection).to receive(:verify).and_return(payload)
      allow(Agents::TicketQueues::Selection).to receive(:valid_payload?).and_return(true)
      allow(snapshot).to receive(:load).and_return(context)
      allow(snapshot).to receive(:eligible?).and_return(true)
    end

    it "rilegge lo snapshot sotto lock dopo aver riservato il limite" do
      reservation = instance_double(Agents::LimitReservation)
      decision = Struct.new(:reservation).new(reservation)
      allow(claim).to receive(:reserve_limit).and_return(Result.ok(decision))
      allow(snapshot).to receive(:lock).and_return(nil)

      expect(claim.call.error.code).to eq("R404-QUEUE-001")

      # Rivalidazione sotto lock host-first: lo snapshot non è più eleggibile → stale (nessun gate agent).
      allow(snapshot).to receive(:lock).and_return(context)
      allow(snapshot).to receive(:eligible?).and_return(true, false)
      expect(claim.call.error.code).to eq("R409-QUEUE-001")
    end

    it "tratta un errore di reservation come selezione stale con TTL autoritativo" do
      allow(claim).to receive(:reserve_limit).and_return(
        Result.err(AppError.new("transitorio", code: "R503-TEST-001", status: :service_unavailable))
      )

      expect(claim.call.error.code).to eq("R409-QUEUE-001")
    end

    it "rifiuta un token host-bound presentato da un altro host" do
      other = create(:agent_host, organization:)
      foreign_claim = described_class.new(organization:, host: other,
                                          selection_token: "token", params: { host_id: other.id, run_id: "run", ttl_seconds: 3600 })

      expect(foreign_claim.call.error.code).to eq("R404-QUEUE-001")
    end
  end
end
