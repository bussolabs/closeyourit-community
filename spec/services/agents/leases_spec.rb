# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Agents::Leases services" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let(:ticket) { create(:ticket, organization:, project:) }
  let(:host) { create(:agent_host, organization:) }
  let(:other_host) { create(:agent_host, organization:) }
  let(:database_now) { Time.zone.parse("2026-07-13 14:00:00") }
  let(:ticket_reference) { ticket.code }
  let(:base_params) do
    { ticket: ticket_reference, host_id: host.id, run_id: "run-42", agent: "triage", ttl_seconds: 60 }
  end

  def acquire(host: self.host, params: base_params)
    Agents::Leases::Acquire.call(organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params:)
  end

  def renew(host: self.host, params: base_params.except(:agent))
    Agents::Leases::Renew.call(organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params:)
  end

  def release(host: self.host, params: base_params.except(:agent, :ttl_seconds))
    Agents::Leases::Release.call(organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params:)
  end

  before do
    [ host, other_host ].each do |agent_host|
      account = agent_host.service_account || create(:account, :service)
      create(:membership, account: account, organization: organization, role: :member) unless account.memberships.exists?(organization_id: organization.id)
      agent_host.update!(service_account: account)
      create(:project_membership, account: account, project: project)
    end
    allow(Agents::Leases::Clock).to receive(:current).and_return(database_now)
  end

  it "refuses acquisition when the host cannot see the ticket project" do
    host.service_account.project_memberships.find_by!(project: project).destroy!
    expect(acquire).to be_err
    expect(Agents::Lease.where(ticket: ticket)).not_to exist
  end

  it "refuses renewal after scope revocation but still permits releasing the lease" do
    expect(acquire).to be_ok
    host.service_account.project_memberships.find_by!(project: project).destroy!
    expect(renew).to be_err
    expect(release).to be_ok
  end

  describe "acquire" do
    it "crea con scadenza esclusivamente server-side" do
      travel_to(database_now + 10.years) do
        result = acquire(params: base_params.merge(expires_at: 10.years.from_now))

        expect(result).to be_ok
        expect(result.value.fresh_acquisition).to be(true)
        expect(result.value.lease).to have_attributes(
          organization:, ticket:, host:, run_id: "run-42", agent: "triage", expires_at: database_now + 60.seconds
        )
      end
    end


    it "ignora lo skew del clock applicativo quando valuta una lease attiva" do
      lease = create(:agent_lease, organization:, ticket:, host:, expires_at: database_now + 5.seconds)

      travel_to(database_now + 10.seconds) do
        result = acquire(
          host: other_host,
          params: base_params.merge(host_id: other_host.id, run_id: "run-other")
        )

        expect(result.error).to have_attributes(code: "R409-LEASE-001", status: :conflict)
        expect(lease.reload.host).to eq(host)
      end
    end

    it "è idempotente per lo stesso host e run senza estendere la scadenza" do
      first = acquire.value

      allow(Agents::Leases::Clock).to receive(:current).and_return(database_now + 10.seconds)
      expect { @retry = acquire }.not_to change(Agents::Lease, :count)

      expect(@retry).to be_ok
      expect(@retry.value.fresh_acquisition).to be(false)
      expect(@retry.value.lease.id).to eq(first.lease.id)
      expect(@retry.value.lease.expires_at).to eq(first.lease.expires_at)
    end

    it "restituisce conflict e holder per un proprietario diverso" do
      held = acquire.value.lease
      other_host_result = acquire(
        host: other_host,
        params: base_params.merge(host_id: other_host.id, run_id: "run-other")
      )
      other_run_result = acquire(params: base_params.merge(run_id: "run-other"))

      expect([ other_host_result, other_run_result ]).to all(be_err)
      expect([ other_host_result.error, other_run_result.error ])
        .to all(have_attributes(code: "R409-LEASE-001", status: :conflict))
      expect(other_host_result.error.details.fetch(:holder).fetch(:host_id)).to eq(held.host_id)
    end

    it "un secondo prima è held, all'istante e un secondo dopo è acquisibile" do
      expires_at = Time.zone.parse("2026-07-13 15:00:00")
      [ -1.second, 0.seconds, 1.second ].each do |offset|
        lease = create(:agent_lease, organization:, ticket:, host:, expires_at:)
        allow(Agents::Leases::Clock).to receive(:current).and_return(lease.expires_at + offset)
        result = acquire(host: other_host, params: base_params.merge(host_id: other_host.id, run_id: "run-#{offset}"))
        if offset.negative?
          expect(result.error.code).to eq("R409-LEASE-001")
        else
          expect(result).to be_ok
        end
        lease.destroy! if lease.persisted?
      end
    end

    it "tombstona il run scaduto prima del passaggio e ne blocca la riacquisizione ritardata" do
      original = acquire.value.lease
      allow(Agents::Leases::Clock).to receive(:current).and_return(original.expires_at)

      successor_params = base_params.merge(host_id: other_host.id, run_id: "run-next")
      successor = acquire(host: other_host, params: successor_params)

      expect(successor).to be_ok
      expect(successor.value.lease).to have_attributes(id: original.id, host: other_host, run_id: "run-next")
      expect(Agents::Leases::Tombstone.where(ticket:, host:, run_id: "run-42")).to exist

      expect(release(host: other_host, params: successor_params.except(:agent, :ttl_seconds))).to be_ok
      expect { @late_acquire = acquire }.not_to change(Agents::Lease, :count)
      expect(@late_acquire.error).to have_attributes(code: "R409-LEASE-002", status: :conflict)
    end

    it "conclude il run che tenta di riacquisire la propria lease già scaduta" do
      expired = acquire.value.lease
      allow(Agents::Leases::Clock).to receive(:current).and_return(expired.expires_at)

      expect { @result = acquire }
        .to change(Agents::Lease, :count).by(-1)
        .and change(Agents::Leases::Tombstone, :count).by(1)

      expect(@result.error).to have_attributes(code: "R409-LEASE-002", status: :conflict)
      expect(Agents::Leases::Tombstone.where(ticket:, host:, run_id: "run-42")).to exist
    end

    it "annulla la tombstone se il passaggio della lease scaduta fallisce" do
      expired = acquire.value.lease
      allow(Agents::Leases::Clock).to receive(:current).and_return(expired.expires_at)
      allow_any_instance_of(Agents::Lease).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(expired))

      result = nil
      expect do
        result = acquire(
          host: other_host,
          params: base_params.merge(host_id: other_host.id, run_id: "run-next")
        )
      end.not_to change(Agents::Leases::Tombstone, :count)

      expect(result.error).to have_attributes(code: "R422-LEASE-001")
      expect(expired.reload).to have_attributes(host:, run_id: "run-42")
    end

    it "limita i retry se lo stato viene rimosso ripetutamente" do
      allow(Agents::Lease).to receive(:create_or_find_by!).and_raise(ActiveRecord::RecordNotFound)

      result = acquire

      expect(Agents::Lease).to have_received(:create_or_find_by!).exactly(3).times
      expect(result.error).to have_attributes(code: "R503-LEASE-001", status: :service_unavailable)
    end

    it "limita i retry anche se la riga scompare prima del lock" do
      lock_attempts = 0
      allow_any_instance_of(Agents::Lease).to receive(:lock!).and_wrap_original do |original|
        lock_attempts += 1
        original.receiver.delete
        raise ActiveRecord::RecordNotFound
      end

      result = acquire

      expect(lock_attempts).to eq(3)
      expect(result.error).to have_attributes(code: "R503-LEASE-001", status: :service_unavailable)
      expect(Agents::Lease.count).to eq(0)
    end
  end

  describe "acquire host-first (CYAU-96)" do
    let(:host_first_params) do
      { ticket: ticket_reference, host_id: host.id, run_id: "run-hf", execution_phase: "triage", ttl_seconds: 60 }
    end

    it "crea un lease host-owned con execution_phase e profile_digest derivato dal PhaseProfile" do
      result = Agents::Leases::Acquire.call(organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params: host_first_params)

      expect(result).to be_ok
      expect(result.value.lease).to have_attributes(
        agent: nil, execution_phase: "triage", profile_digest: Agents::PhaseProfile.for("triage").digest
      )
    end

    it "ignora un profile_digest asserito dal client e usa l'autorità server (PhaseProfile)" do
      tampered = host_first_params.merge(profile_digest: "f" * 64)
      result = Agents::Leases::Acquire.call(organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params: tampered)

      expect(result.value.lease.profile_digest).to eq(Agents::PhaseProfile.for("triage").digest)
    end

    it "rifiuta un execution_phase sconosciuto (fail-closed) senza scrivere" do
      result = Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params: host_first_params.merge(execution_phase: "nope")
      )

      expect(result.error.code).to eq("R422-LEASE-001")
      expect(Agents::Lease.count).to eq(0)
    end

    it "rifiuta una execution_phase sconosciuta in modo coerente anche su un lease legacy attivo già posseduto" do
      create(:agent_lease, organization:, ticket:, host:, run_id: "run-hf", agent: "legacy",
                           expires_at: database_now + 1.hour)

      result = Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params: host_first_params.merge(execution_phase: "unknown")
      )

      expect(result.error.code).to eq("R422-LEASE-001")
      expect(Agents::Lease.where(execution_phase: "unknown")).not_to exist
    end

    it "rifiuta un acquire privo sia di agent sia di execution_phase (nessuna identità di lavoro)" do
      result = Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params: host_first_params.except(:execution_phase)
      )

      expect(result.error.code).to eq("R422-LEASE-001")
      expect(Agents::Lease.count).to eq(0)
    end

    it "converte un lease legacy in host-first in un acquire diretto, cappando la scadenza al TTL della fase" do
      create(:agent_lease, organization:, ticket:, host:, run_id: "run-hf", agent: "legacy",
                           expires_at: database_now + 10.days)

      result = Agents::Leases::Acquire.call(organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params: host_first_params)

      expect(result).to be_ok
      expect(Agents::Lease.find_by(ticket:)).to have_attributes(
        execution_phase: "triage",
        profile_digest: Agents::PhaseProfile.for("triage").digest,
        expires_at: database_now + Agents::PhaseProfile.for("triage").ttl.seconds
      )
    end

    it "non muta lo slug agent di un lease legacy in un retry diretto idempotente (preserva la delivery legacy)" do
      legacy = create(:agent_lease, organization:, ticket:, host:, run_id: "run-hf", agent: "original",
                                    expires_at: database_now + 1.hour)

      result = Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:,
        params: { ticket: ticket_reference, host_id: host.id, run_id: "run-hf", agent: "different", ttl_seconds: 60 }
      )

      expect(result).to be_ok
      expect(legacy.reload.agent).to eq("original")
    end

    it "non estende la deadline autoritativa di un lease legacy nella conversione host-first diretta" do
      deadline = database_now + 30.seconds
      create(:agent_lease, organization:, ticket:, host:, run_id: "run-hf", agent: "legacy",
                           expires_at: deadline, authoritative_ttl_seconds: 3600)

      result = Agents::Leases::Acquire.call(organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params: host_first_params)

      expect(result).to be_ok
      expect(Agents::Lease.find_by(ticket:).expires_at).to eq(deadline)
    end

    it "non estende un lease legacy con scadenza inferiore al TTL della fase alla conversione diretta" do
      near = database_now + 30.seconds
      create(:agent_lease, organization:, ticket:, host:, run_id: "run-hf", agent: "legacy", expires_at: near)

      result = Agents::Leases::Acquire.call(organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params: host_first_params)

      expect(result).to be_ok
      expect(Agents::Lease.find_by(ticket:).expires_at).to eq(near)
    end

    it "deriva la scadenza host-first diretta dal TTL del PhaseProfile, ignorando il ttl del client" do
      result = Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params: host_first_params.merge(ttl_seconds: 86_400)
      )

      expect(result).to be_ok
      expect(result.value.lease).to have_attributes(
        authoritative_ttl_seconds: nil,
        expires_at: database_now + Agents::PhaseProfile.for("triage").ttl.seconds
      )
    end

    it "rifiuta un retry se il PhaseProfile pinnato è cambiato (drift), senza toccare il pin" do
      original = Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:,
        params: host_first_params, authoritative_expires_at: database_now + 60.seconds
      ).value.lease
      pinned = original.profile_digest

      allow(Agents::PhaseProfile).to receive(:for).with("triage")
        .and_return(instance_double(Agents::PhaseProfile, digest: "d" * 64, ttl: 3600))

      result = Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:,
        params: host_first_params, authoritative_expires_at: database_now + 90.seconds
      )

      expect(result.error).to have_attributes(code: "R409-LEASE-005", status: :conflict)
      expect(original.reload.profile_digest).to eq(pinned)
    end

    it "rifiuta con conflict un retry dello stesso run che cambia fase su un lease attivo" do
      Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:,
        params: host_first_params, authoritative_expires_at: database_now + 60.seconds
      )

      result = Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:,
        params: host_first_params.merge(execution_phase: "planner"), authoritative_expires_at: database_now + 60.seconds
      )

      expect(result.error).to have_attributes(code: "R409-LEASE-006", status: :conflict)
    end
  end

  describe "renew" do
    it "rinnova dal tempo server senza cambiare proprietario" do
      lease = acquire.value.lease

      allow(Agents::Leases::Clock).to receive(:current).and_return(database_now + 30.seconds)
      result = renew(params: base_params.except(:agent).merge(ttl_seconds: 120, expires_at: 10.years.from_now))

      expect(result).to be_ok
      expect(result.value).to have_attributes(
        id: lease.id, host:, run_id: "run-42", expires_at: database_now + 150.seconds
      )
    end

    it "nega un altro host o run con holder" do
      held = acquire.value.lease
      other_host_result = renew(
        host: other_host,
        params: base_params.except(:agent).merge(host_id: other_host.id, run_id: "other")
      )
      other_run_result = renew(params: base_params.except(:agent).merge(run_id: "other"))

      expect([ other_host_result.error.code, other_run_result.error.code ]).to all(eq("R409-LEASE-001"))
      expect(other_host_result.error.details.dig(:holder, :host_id)).to eq(held.host_id)
    end

    it "funziona un secondo prima ma è expired all'istante e un secondo dopo" do
      expires_at = Time.zone.parse("2026-07-13 15:00:00")
      [ -1.second, 0.seconds, 1.second ].each do |offset|
        lease = create(:agent_lease, organization:, ticket:, host:, run_id: "run-42", expires_at:)

        allow(Agents::Leases::Clock).to receive(:current).and_return(lease.expires_at + offset)
        result = renew
        if offset.negative?
          expect(result).to be_ok
        else
          expect(result.error.code).to eq("R404-LEASE-002")
        end
        lease.destroy! if lease.persisted?
      end
    end

    it "tombstona e rimuove atomicamente una lease scaduta prima di rispondere not found" do
      expired = acquire.value.lease
      allow(Agents::Leases::Clock).to receive(:current).and_return(expired.expires_at)

      expect { @result = renew }
        .to change(Agents::Lease, :count).by(-1)
        .and change(Agents::Leases::Tombstone, :count).by(1)

      expect(@result.error).to have_attributes(code: "R404-LEASE-002", status: :not_found)
      expect(Agents::Leases::Tombstone.where(ticket:, host:, run_id: "run-42")).to exist
      expect(acquire.error).to have_attributes(code: "R409-LEASE-002", status: :conflict)

      successor = acquire(
        host: other_host,
        params: base_params.merge(host_id: other_host.id, run_id: "run-next")
      )
      expect(successor).to be_ok
    end

    it "annulla la tombstone se la rimozione della lease scaduta fallisce" do
      expired = acquire.value.lease
      allow(Agents::Leases::Clock).to receive(:current).and_return(expired.expires_at)
      allow_any_instance_of(Agents::Lease).to receive(:destroy!)
        .and_raise(ActiveRecord::RecordNotDestroyed.new("rimozione forzatamente fallita", expired))

      expect { renew }.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(Agents::Leases::Tombstone.where(ticket:, host:, run_id: "run-42")).not_to exist
      expect(expired.reload).to be_persisted
    end
  end

  describe "release" do
    it "rilascia solo il lease posseduto e rende il retry idempotente tramite tombstone" do
      acquire

      expect { @released = release }
        .to change(Agents::Lease, :count).by(-1)
        .and change(Agents::Leases::Tombstone, :count).by(1)
      expect(@released).to be_ok
      expect { @retried = release }.not_to change(Agents::Leases::Tombstone, :count)
      expect(@retried).to be_ok
    end

    it "non resuscita una lease quando acquire arriva dopo il release dello stesso run" do
      acquire
      release

      expect { @late_acquire = acquire }.not_to change(Agents::Lease, :count)

      expect(@late_acquire.error).to have_attributes(code: "R409-LEASE-002", status: :conflict)
      expect(@late_acquire.error.details).to be_nil
    end

    it "consente subito a un nuovo run di acquisire dopo il release" do
      acquire
      release

      result = acquire(
        host: other_host,
        params: base_params.merge(host_id: other_host.id, run_id: "run-next")
      )

      expect(result).to be_ok
      expect(result.value.lease).to have_attributes(host: other_host, run_id: "run-next")
      expect(Agents::Leases::Tombstone.where(ticket:, host:, run_id: "run-42")).to exist
    end


    it "rende idempotente il retry release senza toccare la lease del run successivo" do
      acquire
      release
      next_acquisition = acquire(
        host: other_host,
        params: base_params.merge(host_id: other_host.id, run_id: "run-next")
      ).value.lease

      expect(release).to be_ok
      expect(next_acquisition.reload).to have_attributes(host: other_host, run_id: "run-next")
    end

    it "nega un altro host o run senza cancellare" do
      held = acquire.value.lease
      other_host_result = release(
        host: other_host,
        params: base_params.except(:agent, :ttl_seconds).merge(host_id: other_host.id, run_id: "other")
      )
      other_run_result = release(params: base_params.except(:agent, :ttl_seconds).merge(run_id: "other"))

      expect([ other_host_result.error.code, other_run_result.error.code ]).to all(eq("R409-LEASE-001"))
      expect(held.reload).to be_persisted
    end

    it "rilascia un secondo prima ma considera scaduto l'istante esatto e quello successivo" do
      expires_at = Time.zone.parse("2026-07-13 15:00:00")
      [ -1.second, 0.seconds, 1.second ].each do |offset|
        run_id = "run-boundary-#{offset.to_i}"
        lease = create(:agent_lease, organization:, ticket:, host:, run_id:, expires_at:)

        allow(Agents::Leases::Clock).to receive(:current).and_return(lease.expires_at + offset)
        result = release(params: base_params.except(:agent, :ttl_seconds).merge(run_id:))
        expect(result).to be_ok if offset.negative?
        expect(result.error.code).to eq("R404-LEASE-002") unless offset.negative?
        lease.destroy! if lease.persisted?
      end
    end
  end

  describe "renew/release host-first (CYAU-96)" do
    let(:host_first_params) do
      { ticket: ticket_reference, host_id: host.id, run_id: "run-hf", execution_phase: "triage", ttl_seconds: 60 }
    end

    before { Agents::Leases::Acquire.call(organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params: host_first_params) }

    it "rinnova un lease host-first (nessun agent) conservando la fase" do
      result = Agents::Leases::Renew.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:,
        params: host_first_params.except(:execution_phase).merge(ttl_seconds: Agents::PhaseProfile.for("triage").ttl)
      )

      expect(result).to be_ok
      expect(result.value).to have_attributes(agent: nil, execution_phase: "triage")
    end

    it "estende la scadenza di un lease host-first diretto al renew, cappando al TTL della fase" do
      later = database_now + 100.seconds
      allow(Agents::Leases::Clock).to receive(:current).and_return(later)

      result = Agents::Leases::Renew.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:,
        params: host_first_params.except(:execution_phase).merge(ttl_seconds: 86_400)
      )

      expect(result).to be_ok
      expect(result.value.expires_at).to eq(later + Agents::PhaseProfile.for("triage").ttl.seconds)
    end

    it "rilascia un lease host-first (nessun agent) tramite tombstone del run" do
      result = Agents::Leases::Release.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:, params: host_first_params.except(:execution_phase, :ttl_seconds)
      )

      expect(result).to be_ok
      expect(Agents::Lease.where(ticket:)).not_to exist
      expect(Agents::Leases::Tombstone.where(ticket:, host:, run_id: "run-hf")).to exist
    end

    it "fallisce chiuso al renew se il PhaseProfile è cambiato rispetto al digest pinnato" do
      allow(Agents::PhaseProfile).to receive(:for).with("triage")
        .and_return(instance_double(Agents::PhaseProfile, digest: "d" * 64, ttl: 3600))

      result = Agents::Leases::Renew.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:,
        params: host_first_params.except(:execution_phase).merge(ttl_seconds: 3600)
      )

      expect(result.error).to have_attributes(code: "R409-LEASE-005", status: :conflict)
    end

    it "rifiuta un renew che dichiara una execution_phase diversa da quella pinnata sul lease" do
      result = Agents::Leases::Renew.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:,
        params: host_first_params.merge(execution_phase: "planner", ttl_seconds: Agents::PhaseProfile.for("triage").ttl)
      )

      expect(result.error).to have_attributes(code: "R409-LEASE-006", status: :conflict)
    end
  end

  describe "validazione, ownership e BOLA" do
    it "rifiuta TTL non interi positivi" do
      invalid_ttls = [ 0, -1, 1.5, "60", nil, Agents::Leases::Operation::MAX_TTL_SECONDS + 1 ]

      invalid_ttls.each do |ttl|
        expect(acquire(params: base_params.merge(ttl_seconds: ttl)).error.code).to eq("R422-LEASE-001")
      end

      expect(acquire(params: base_params.merge(ttl_seconds: Agents::Leases::Operation::MAX_TTL_SECONDS))).to be_ok
    end

    it "rifiuta run e agent vuoti o oltre il limite prima di scrivere" do
      oversized = "x" * (Agents::Leases::Operation::MAX_IDENTIFIER_LENGTH + 1)

      [ nil, "   ", oversized ].each do |run_id|
        expect(acquire(params: base_params.merge(run_id:)).error.code).to eq("R422-LEASE-001")
      end
      [ nil, "   ", oversized ].each do |agent|
        expect(acquire(params: base_params.merge(agent:)).error.code).to eq("R422-LEASE-001")
      end
      expect(Agents::Lease.count).to eq(0)
    end

    it "rifiuta l'host_id che non coincide col token" do
      result = acquire(params: base_params.merge(host_id: other_host.id))

      expect(result.error).to have_attributes(code: "R403-LEASE-001", status: :forbidden)
      expect(Agents::Lease.count).to eq(0)
    end

    it "non risolve ticket di un'altra organization in nessuna operazione" do
      foreign = create(:ticket, organization: create(:organization))
      foreign_params = base_params.merge(ticket: foreign.code)
      acquire_result = Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: foreign.code,
        params: foreign_params
      )
      renew_result = Agents::Leases::Renew.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: foreign.code,
        params: foreign_params.except(:agent)
      )
      release_result = Agents::Leases::Release.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: foreign.code,
        params: foreign_params.except(:agent, :ttl_seconds)
      )

      expect([ acquire_result.error, renew_result.error, release_result.error ])
        .to all(have_attributes(code: "R404-LEASE-001", status: :not_found))
    end

    it "rifiuta ticket malformato e mismatch path/body" do
      malformed = Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: "../CYAU-1",
        params: base_params.merge(ticket: "../CYAU-1")
      )
      mismatch = Agents::Leases::Renew.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference:,
        params: base_params.except(:agent).merge(ticket: "CYAU-999")
      )

      expect(malformed.error.code).to eq("R422-LEASE-001")
      expect(mismatch.error.code).to eq("R422-LEASE-001")
    end

    it "rifiuta numeri ticket oltre il range PostgreSQL in tutte le operazioni" do
      [ "CYAU-2147483648", "CYAU-#{"9" * 100}" ].each do |overflow_reference|
        overflow_params = base_params.merge(ticket: overflow_reference)

        expect do
          @overflow_results = [
            Agents::Leases::Acquire.call(
              organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: overflow_reference, params: overflow_params
            ),
            Agents::Leases::Renew.call(
              organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: overflow_reference, params: overflow_params.except(:agent)
            ),
            Agents::Leases::Release.call(
              organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: overflow_reference,
              params: overflow_params.except(:agent, :ttl_seconds)
            )
          ]
        end.not_to change(Agents::Lease, :count)

        expect(@overflow_results.map { |result| result.error.code }).to all(eq("R422-LEASE-001"))
      end

      maximum_reference = "CYAU-2147483647"
      maximum_result = Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: maximum_reference,
        params: base_params.merge(ticket: maximum_reference)
      )
      expect(maximum_result.error.code).to eq("R404-LEASE-001")
    end
  end

  # CYRA-293 — il titolare account (canale CLI: persona o service account) usa le stesse operazioni.
  describe "titolare account" do
    let(:account) { create(:membership, organization:).account }
    let(:other_account) { create(:membership, organization:).account }
    let(:account_holder) { Agents::Leases::Holder.account(account) }
    let(:account_params) { { ticket: ticket_reference, run_id: "cli-1", ttl_seconds: 3600 } }

    def account_acquire(holder: account_holder, params: account_params)
      Agents::Leases::Acquire.call(organization:, holder:, ticket_reference:, params:)
    end

    it "prende il ticket senza identità di lavoro agente" do
      result = account_acquire

      expect(result).to be_ok
      expect(result.value.lease).to have_attributes(
        account:, host: nil, agent: nil, execution_phase: nil, run_id: "cli-1",
        expires_at: database_now + 3600.seconds
      )
    end

    it "esclude un host da un ticket già preso da un account, e viceversa" do
      expect(account_acquire).to be_ok

      host_attempt = acquire

      expect(host_attempt.error).to have_attributes(code: "R409-LEASE-001", status: :conflict)
      expect(host_attempt.error.details.dig(:holder, :held_by))
        .to include(kind: :account, id: account.id, name: account.name)
    end

    it "esclude un account da un ticket già preso da un host" do
      expect(acquire).to be_ok

      result = account_acquire

      expect(result.error).to have_attributes(code: "R409-LEASE-001", status: :conflict)
      expect(result.error.details.dig(:holder, :held_by)).to include(kind: :host, id: host.id)
    end

    it "non riconosce come proprietario un altro account con lo stesso run" do
      expect(account_acquire).to be_ok

      result = account_acquire(holder: Agents::Leases::Holder.account(other_account))

      expect(result.error).to have_attributes(code: "R409-LEASE-001", status: :conflict)
    end

    it "rinnova e rilascia il proprio lease, e il rilascio libera il ticket per un host" do
      expect(account_acquire).to be_ok

      renewal = Agents::Leases::Renew.call(
        organization:, holder: account_holder, ticket_reference:, params: account_params
      )
      release = Agents::Leases::Release.call(
        organization:, holder: account_holder, ticket_reference:, params: account_params.except(:ttl_seconds)
      )

      expect(renewal).to be_ok
      expect(release).to be_ok
      expect(acquire).to be_ok
    end

    it "rifiuta un host_id dichiarato nel body: sul canale account il titolare viene dal token" do
      result = account_acquire(params: account_params.merge(host_id: host.id))

      expect(result.error).to have_attributes(code: "R422-LEASE-001", status: :unprocessable_content)
      expect(Agents::Lease.count).to eq(0)
    end

    it "rifiuta un account che non appartiene all'organizzazione" do
      result = account_acquire(holder: Agents::Leases::Holder.account(create(:account)))

      expect(result.error).to have_attributes(code: "R403-LEASE-002", status: :forbidden)
      expect(Agents::Lease.count).to eq(0)
    end

    # Un lease scaduto di un ex membro deve poter passare di mano: Acquire tombstona la riga PRIMA di
    # consegnarla al titolare successivo, e se il tombstone pretendesse la membership corrente quel
    # ticket resterebbe occupato da un lease morto per sempre.
    it "lascia riprendere un ticket il cui titolare ha lasciato l'organizzazione" do
      expect(account_acquire).to be_ok
      Agents::Lease.where(ticket:).update_all(expires_at: database_now - 1.second)
      Connections::Membership.find_by(organization:, account:).destroy!

      expect(acquire).to be_ok
      expect(Agents::Lease.where(ticket:).sole.host_id).to eq(host.id)
    end

    it "tiene la memoria del rilascio separata per titolare: il tombstone di un account non blocca un host" do
      expect(account_acquire).to be_ok
      expect(
        Agents::Leases::Release.call(
          organization:, holder: account_holder, ticket_reference:, params: account_params.except(:ttl_seconds)
        )
      ).to be_ok

      expect(account_acquire).to be_err
      expect(acquire).to be_ok
    end
  end
end
