# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Agents::Leases::Acquire, "concorrenza PostgreSQL reale" do
  self.use_transactional_tests = false

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let(:reporter) do
    nonce = SecureRandom.hex(8)
    create(:account, email: "lease-concurrency-#{nonce}@example.com", handle: "lease_concurrency_#{nonce}")
  end
  let(:ticket) { create(:ticket, organization:, project:, reporter:, reviewer: reporter) }
  let(:hosts) { create_list(:agent_host, 2, organization:) }

  before do
    hosts.each do |agent_host|
      account = agent_host.service_account || create(:account, :service)
      create(:membership, account: account, organization: organization, role: :member) unless account.memberships.exists?(organization_id: organization.id)
      agent_host.update!(service_account: account)
      create(:project_membership, account: account, project: project)
    end
    create(:membership, account: reporter, organization:, role: :member)
    ticket
    hosts
  end

  after do
    # B.1 — gli host registrati via Register coniano un service account: raccoglilo PRIMA di distruggere
    # l'org (la FK è nullify, non cascade) e cancellalo, così non si accumula nel DB test non-transazionale.
    # Stessa ragione per gli account membri creati dai singoli esempi (titolari account, CYRA-293): la
    # distruzione dell'org porta via le membership ma non gli account, che resterebbero a collidere con
    # la sequenza della factory al run successivo.
    leftover_accounts = []
    if organization.persisted?
      leftover_accounts += organization.agent_hosts.filter_map(&:service_account)
      leftover_accounts += organization.accounts.to_a
    end
    leftover_accounts << reporter
    ticket.destroy! if ticket.persisted?
    organization.reload.destroy! if organization.persisted?
    # Un solo passaggio per id: il reporter compare anche fra i membri dell'org, e una seconda
    # destroy! sulla stessa riga solleverebbe RecordNotFound.
    Accounts::Account.where(id: leftover_accounts.map(&:id).uniq).destroy_all
  end

  it "concede lo stesso ticket a un solo host sotto acquire simultanei" do
    waiting = 0
    mutex = Mutex.new
    barrier = ConditionVariable.new
    threads = []

    allow_any_instance_of(Ticketing::Ticket).to receive(:lock!).and_wrap_original do |original, *args|
      mutex.synchronize do
        waiting += 1
        barrier.broadcast
        barrier.wait(mutex) while waiting < 2
      end
      original.call(*args)
    end

    threads = hosts.map do |host|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.call(
            organization: Organizations::Organization.find(organization.id),
            holder: Agents::Leases::Holder.host(Agents::Host.find(host.id)),
            ticket_reference: ticket.code,
            params: { ticket: ticket.code, host_id: host.id, run_id: "run-#{host.id}",
                      agent: "triage", ttl_seconds: 60 }
          )
        end
      end
    end
    results = Timeout.timeout(10) { threads.map(&:value) }

    expect(results.count(&:ok?)).to eq(1)
    expect(results.count { |result| result.err? && result.error.code == "R409-LEASE-001" }).to eq(1)
    expect(Agents::Lease.where(ticket:).sole.host_id).to eq(results.find(&:ok?).value.lease.host_id)
  ensure
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  # CYRA-293 — il caso che motiva tutto il lavoro: un host automator e una persona che partono insieme.
  # Se i due titolari vivessero in tabelle separate passerebbero entrambi, ed è esattamente il doppio
  # lavoro da impedire.
  it "concede lo stesso ticket a un solo titolare quando un host e un account partono insieme" do
    account = create(:membership, organization:).account
    waiting = 0
    mutex = Mutex.new
    barrier = ConditionVariable.new
    threads = []

    allow_any_instance_of(Ticketing::Ticket).to receive(:lock!).and_wrap_original do |original, *args|
      mutex.synchronize do
        waiting += 1
        barrier.broadcast
        barrier.wait(mutex) while waiting < 2
      end
      original.call(*args)
    end

    contenders = [
      [ Agents::Leases::Holder.host(hosts.first),
        { ticket: ticket.code, host_id: hosts.first.id, run_id: "host-run", agent: "triage", ttl_seconds: 60 } ],
      [ Agents::Leases::Holder.account(account),
        { ticket: ticket.code, run_id: "cli-run", ttl_seconds: 60 } ]
    ]
    threads = contenders.map do |holder, params|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.call(
            organization: Organizations::Organization.find(organization.id),
            holder:, ticket_reference: ticket.code, params:
          )
        end
      end
    end
    results = Timeout.timeout(10) { threads.map(&:value) }

    expect(results.count(&:ok?)).to eq(1)
    expect(results.count { |result| result.err? && result.error.code == "R409-LEASE-001" }).to eq(1)
    winner = results.find(&:ok?).value.lease
    expect(Agents::Lease.where(ticket:).sole).to have_attributes(id: winner.id, holder_id: winner.holder_id)
  ensure
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "serializza release e nuovo acquire senza esporre il race delete-select sul wire" do
    owner_registration = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "owner", platform: "linux", arch: "amd64"
    ).value
    contender_registration = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "contender", platform: "linux", arch: "amd64"
    ).value
    owner = owner_registration.fetch(:host)
    create(:project_membership, account: owner.service_account, project:)
    contender = contender_registration.fetch(:host)
    create(:project_membership, account: contender.service_account, project:)
    create(:agent_lease, organization:, ticket:, host: owner, run_id: "owner-run")

    release_locked = Queue.new
    acquire_attempted = Queue.new
    threads = []

    allow_any_instance_of(Agents::Leases::Release).to receive(:owned?).and_wrap_original do |original, lease|
      if Thread.current[:lease_operation] == :release
        release_locked << true
        acquire_attempted.pop
      end
      original.call(lease)
    end
    allow_any_instance_of(Ticketing::Ticket).to receive(:lock!).and_wrap_original do |original, *args|
      acquire_attempted << true if Thread.current[:lease_operation] == :acquire
      original.call(*args)
    end

    threads << Thread.new do
      Thread.current[:lease_operation] = :release
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post(
        "/api/v1/leases/#{ticket.code}/release",
        params: { ticket: ticket.code, host_id: owner.id, run_id: "owner-run" },
        headers: { "Authorization" => "Bearer #{owner_registration.fetch(:secret)}" }, as: :json
      )
      { status: session.response.status, body: session.response.parsed_body }
    end
    Timeout.timeout(5) { release_locked.pop }

    threads << Thread.new do
      Thread.current[:lease_operation] = :acquire
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post(
        "/api/v1/leases",
        params: { ticket: ticket.code, host_id: contender.id, run_id: "contender-run",
                  agent: "triage", ttl_seconds: 60 },
        headers: { "Authorization" => "Bearer #{contender_registration.fetch(:secret)}" }, as: :json
      )
      { status: session.response.status, body: session.response.parsed_body }
    end
    responses = Timeout.timeout(10) { threads.map(&:value) }

    expect(responses.map { |item| item.fetch(:status) }).to eq([ 200, 201 ])
    expect(responses.last.dig(:body, "data", "host_id")).to eq(contender.id)
    expect(Agents::Lease.where(ticket:).sole).to have_attributes(host: contender, run_id: "contender-run")
    expect(Agents::Leases::Tombstone.where(ticket:, host: owner, run_id: "owner-run")).to exist
  ensure
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "blocca un acquire duplicato che arriva mentre il release rende durevole la tombstone" do
    owner = hosts.first
    create(:agent_lease, organization:, ticket:, host: owner, run_id: "owner-run")
    tombstone_written = Queue.new
    acquire_attempted = Queue.new
    threads = []

    allow(Agents::Leases::Tombstone).to receive(:record!).and_wrap_original do |original, **kwargs|
      tombstone = original.call(**kwargs)
      if Thread.current[:lease_operation] == :release
        tombstone_written << true
        acquire_attempted.pop
      end
      tombstone
    end
    allow_any_instance_of(Agents::Host).to receive(:lock!).and_wrap_original do |original, *args|
      acquire_attempted << true if Thread.current[:lease_operation] == :late_acquire
      original.call(*args)
    end

    threads << Thread.new do
      Thread.current[:lease_operation] = :release
      ActiveRecord::Base.connection_pool.with_connection do
        Agents::Leases::Release.call(
          organization: Organizations::Organization.find(organization.id),
          holder: Agents::Leases::Holder.host(Agents::Host.find(owner.id)),
          ticket_reference: ticket.code,
          params: { ticket: ticket.code, host_id: owner.id, run_id: "owner-run" }
        )
      end
    end
    Timeout.timeout(5) { tombstone_written.pop }

    threads << Thread.new do
      Thread.current[:lease_operation] = :late_acquire
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(
          organization: Organizations::Organization.find(organization.id),
          holder: Agents::Leases::Holder.host(Agents::Host.find(owner.id)),
          ticket_reference: ticket.code,
          params: { ticket: ticket.code, host_id: owner.id, run_id: "owner-run",
                    agent: "triage", ttl_seconds: 60 }
        )
      end
    end
    released, late_acquire = Timeout.timeout(10) { threads.map(&:value) }

    expect(released).to be_ok
    expect(late_acquire.error).to have_attributes(code: "R409-LEASE-002", status: :conflict)
    expect(Agents::Lease.where(ticket:)).not_to exist
    expect(Agents::Leases::Tombstone.where(ticket:, host: owner, run_id: "owner-run")).to exist
  ensure
    acquire_attempted << true if defined?(acquire_attempted)
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "serializza il run scaduto dietro la tombstone scritta prima del passaggio al successore" do
    owner = hosts.first
    contender = hosts.second
    create(:agent_lease, organization:, ticket:, host: owner, run_id: "owner-run", expires_at: 1.minute.ago)
    tombstone_written = Queue.new
    late_acquire_attempted = Queue.new
    threads = []

    allow(Agents::Leases::Tombstone).to receive(:record!).and_wrap_original do |original, **kwargs|
      tombstone = original.call(**kwargs)
      if Thread.current[:lease_operation] == :expired_takeover
        tombstone_written << true
        late_acquire_attempted.pop
      end
      tombstone
    end
    allow_any_instance_of(Agents::Host).to receive(:lock!).and_wrap_original do |original, *args|
      late_acquire_attempted << true if Thread.current[:lease_operation] == :late_expired_owner
      original.call(*args)
    end

    threads << Thread.new do
      Thread.current[:lease_operation] = :expired_takeover
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(
          organization: Organizations::Organization.find(organization.id),
          holder: Agents::Leases::Holder.host(Agents::Host.find(contender.id)),
          ticket_reference: ticket.code,
          params: { ticket: ticket.code, host_id: contender.id, run_id: "contender-run",
                    agent: "triage", ttl_seconds: 60 }
        )
      end
    end
    Timeout.timeout(5) { tombstone_written.pop }

    threads << Thread.new do
      Thread.current[:lease_operation] = :late_expired_owner
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(
          organization: Organizations::Organization.find(organization.id),
          holder: Agents::Leases::Holder.host(Agents::Host.find(owner.id)),
          ticket_reference: ticket.code,
          params: { ticket: ticket.code, host_id: owner.id, run_id: "owner-run",
                    agent: "triage", ttl_seconds: 60 }
        )
      end
    end
    takeover, late_acquire = Timeout.timeout(10) { threads.map(&:value) }

    expect(takeover).to be_ok
    expect(late_acquire.error).to have_attributes(code: "R409-LEASE-002", status: :conflict)
    expect(Agents::Lease.where(ticket:).sole).to have_attributes(host: contender, run_id: "contender-run")
    expect(Agents::Leases::Tombstone.where(ticket:, host: owner, run_id: "owner-run")).to exist

    release = Agents::Leases::Release.call(
      organization:, holder: Agents::Leases::Holder.host(contender), ticket_reference: ticket.code,
      params: { ticket: ticket.code, host_id: contender.id, run_id: "contender-run" }
    )
    expect(release).to be_ok
    expect(Agents::Lease.where(ticket:)).not_to exist
  ensure
    late_acquire_attempted << true if defined?(late_acquire_attempted)
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "mantiene l'ordine ticket→lease tra destroy del ticket e acquire" do
    owner = hosts.first
    contender = hosts.second
    create(:agent_lease, organization:, ticket:, host: owner, run_id: "owner-run")
    destroy_ready = Queue.new
    acquire_locked = Queue.new
    threads = []
    pause_destroy = proc do
      next unless Thread.current[:lease_operation] == :ticket_destroy

      destroy_ready << true
      acquire_locked.pop
    end
    Ticketing::Ticket.set_callback(:destroy, :before, pause_destroy)
    allow_any_instance_of(Ticketing::Ticket).to receive(:lock!).and_wrap_original do |original, *args|
      result = original.call(*args)
      acquire_locked << true if Thread.current[:lease_operation] == :acquire_during_destroy
      result
    end

    threads << Thread.new do
      Thread.current[:lease_operation] = :ticket_destroy
      ActiveRecord::Base.connection_pool.with_connection do
        Ticketing::Ticket.find(ticket.id).destroy!
      end
    end
    Timeout.timeout(5) { destroy_ready.pop }

    threads << Thread.new do
      Thread.current[:lease_operation] = :acquire_during_destroy
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(
          organization: Organizations::Organization.find(organization.id),
          holder: Agents::Leases::Holder.host(Agents::Host.find(contender.id)),
          ticket_reference: ticket.code,
          params: { ticket: ticket.code, host_id: contender.id, run_id: "contender-run",
                    agent: "triage", ttl_seconds: 60 }
        )
      end
    end
    destroyed, acquisition = Timeout.timeout(10) { threads.map(&:value) }

    expect(destroyed).to be_destroyed
    expect(acquisition.error.code).to eq("R409-LEASE-001")
    expect(Ticketing::Ticket.where(id: ticket.id)).not_to exist
    expect(Agents::Lease.where(ticket_id: ticket.id)).not_to exist
  ensure
    Ticketing::Ticket.skip_callback(:destroy, :before, pause_destroy) if defined?(pause_destroy)
    acquire_locked << true if defined?(acquire_locked)
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "recupera il delete tra INSERT fallita e SELECT senza esporre un 404 spurio" do
    owner = hosts.first
    existing = create(:agent_lease, organization:, ticket:, host: owner, run_id: "owner-run")
    contender_registration = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "contender", platform: "linux", arch: "amd64"
    ).value
    contender = contender_registration.fetch(:host)
    create(:project_membership, account: contender.service_account, project:)
    select_pending = Queue.new
    allow_select = Queue.new
    thread = nil

    allow_any_instance_of(ActiveRecord::Relation).to receive(:find_by!).and_wrap_original do |original, *args|
      lease_lookup = original.receiver.klass == Agents::Lease
      if lease_lookup && Thread.current[:lease_operation] == :acquire && !Thread.current[:delete_select_intercepted]
        Thread.current[:delete_select_intercepted] = true
        select_pending << true
        allow_select.pop
      end
      original.call(*args)
    end

    thread = Thread.new do
      Thread.current[:lease_operation] = :acquire
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post(
        "/api/v1/leases",
        params: { ticket: ticket.code, host_id: contender.id, run_id: "contender-run",
                  agent: "triage", ttl_seconds: 60 },
        headers: { "Authorization" => "Bearer #{contender_registration.fetch(:secret)}" }, as: :json
      )
      { status: session.response.status, body: session.response.parsed_body }
    end
    Timeout.timeout(5) { select_pending.pop }
    expect(Agents::Lease.where(id: existing.id).delete_all).to eq(1)
    allow_select << true
    response = Timeout.timeout(10) { thread.value }

    expect(response.fetch(:status)).to eq(201)
    expect(response.dig(:body, "data", "host_id")).to eq(contender.id)
    expect(Agents::Lease.where(ticket:).sole).to have_attributes(host: contender, run_id: "contender-run")
  ensure
    allow_select << true if defined?(allow_select)
    if thread&.alive?
      thread.kill
      thread.join
    end
  end

  it "recupera il delete tra il ritorno della SELECT e il lock della riga lease" do
    owner = hosts.first
    existing = create(:agent_lease, organization:, ticket:, host: owner, run_id: "owner-run")
    contender = hosts.second
    lease_returning = Queue.new
    allow_return = Queue.new
    thread = nil

    allow_any_instance_of(described_class).to receive(:find_or_create_lease).and_wrap_original do |original|
      if Thread.current[:lease_operation] == :acquire && !Thread.current[:lease_return_intercepted]
        Thread.current[:lease_return_intercepted] = true
        # Simula il writer legacy che usa una SELECT senza lock: il record restituito è reale e
        # committed, ma resta cancellabile fino al successivo lease.lock! di Acquire.
        lease = Agents::Lease.find(existing.id)
        lease_returning << lease.id
        allow_return.pop
        lease
      else
        original.call
      end
    end

    thread = Thread.new do
      Thread.current[:lease_operation] = :acquire
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(
          organization: Organizations::Organization.find(organization.id),
          holder: Agents::Leases::Holder.host(Agents::Host.find(contender.id)),
          ticket_reference: ticket.code,
          params: { ticket: ticket.code, host_id: contender.id, run_id: "contender-run",
                    agent: "triage", ttl_seconds: 60 }
        )
      end
    end

    selected_id = Timeout.timeout(5) { lease_returning.pop }
    expect(selected_id).to eq(existing.id)
    expect(Agents::Lease.where(id: selected_id).delete_all).to eq(1)
    allow_return << true
    result = Timeout.timeout(10) { thread.value }

    expect(result).to be_ok
    expect(result.value.fresh_acquisition).to be(true)
    expect(Agents::Lease.where(ticket:).sole).to have_attributes(host: contender, run_id: "contender-run")
  ensure
    allow_return << true if defined?(allow_return)
    if thread&.alive?
      thread.kill
      thread.join
    end
  end
end
