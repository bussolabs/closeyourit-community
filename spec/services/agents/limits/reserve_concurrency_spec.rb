# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Agents::Limits::Reserve, "concorrenza PostgreSQL reale" do
  self.use_transactional_tests = false

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  # Host-first (CYAU-91): input = host + project + phase. "autopilot" → runtime "codex", ttl 3600 (PhaseProfile).
  # Ogni host vede il progetto tramite il proprio service account (ProjectScope host-only).
  let(:phase) { "autopilot" }
  let!(:policy) { create(:agent_limit_policy, organization:, max_parallel: 1) }
  let!(:hosts) { [ host_seeing_project, host_seeing_project ] }

  after do
    host_sas = hosts.map(&:service_account)
    organization.destroy! if organization.persisted?
    host_sas.each { |sa| sa.destroy! if sa&.persisted? }
  end

  it "serializza host diversi sullo stesso limite e concede un solo slot" do
    ready = Queue.new
    release = Queue.new
    threads = []

    allow_any_instance_of(described_class).to receive(:after_policies_locked).and_wrap_original do |original|
      ready << true
      release.pop
      original.call
    end

    threads = hosts.map do |host|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.call(
            organization: Organizations::Organization.find(organization.id),
            host: Agents::Host.find(host.id), project: Projects::Project.find(project.id),
            phase:, idempotency_key: SecureRandom.uuid, estimated_cost: 0
          )
        end
      end
    end

    Timeout.timeout(5) { ready.pop }
    2.times { release << true }
    results = Timeout.timeout(10) { threads.map(&:value) }

    expect(results).to all(be_ok)
    expect(results.map { |result| result.value.reservation.outcome }).to contain_exactly("granted", "denied")
    expect(Agents::LimitReservation.where(outcome: "granted").count).to eq(1)
  ensure
    2.times { release << true }
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "crea atomicamente una sola policy di default senza bloccare organization" do
    policy.destroy!
    waiting = 0
    mutex = Mutex.new
    barrier = ConditionVariable.new
    threads = []

    allow(Agents::LimitPolicy).to receive(:insert_all).and_wrap_original do |original, *args, **kwargs|
      mutex.synchronize do
        waiting += 1
        barrier.broadcast
        barrier.wait(mutex) while waiting < 2
      end
      original.call(*args, **kwargs)
    end

    threads = hosts.map do |host|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.call(
            organization: Organizations::Organization.find(organization.id),
            host: Agents::Host.find(host.id), project: Projects::Project.find(project.id),
            phase:, idempotency_key: SecureRandom.uuid, estimated_cost: 0
          )
        end
      end
    end
    results = Timeout.timeout(10) { threads.map(&:value) }

    expect(results).to all(be_ok)
    expect(Agents::LimitPolicy.where(organization:, project: nil, runtime: nil).count).to eq(1)
    expect(Agents::LimitReservation.where(outcome: "granted").count).to eq(2)
    expect(Agents::LimitUsage.sole.runs).to eq(2)
  ensure
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "serializza il budget di costo e non ammette due claim oltre la soglia" do
    policy.update!(max_parallel: nil, max_daily_cost: 10)
    ready = Queue.new
    release = Queue.new
    threads = []

    allow_any_instance_of(described_class).to receive(:after_policies_locked).and_wrap_original do |original|
      ready << true
      release.pop
      original.call
    end

    threads = hosts.map do |host|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.call(
            organization: Organizations::Organization.find(organization.id),
            host: Agents::Host.find(host.id), project: Projects::Project.find(project.id),
            phase:, idempotency_key: SecureRandom.uuid, estimated_cost: 6
          )
        end
      end
    end

    Timeout.timeout(5) { ready.pop }
    2.times { release << true }
    results = Timeout.timeout(10) { threads.map(&:value) }

    expect(results.map { |result| result.value.reservation.outcome }).to contain_exactly("granted", "denied")
    expect(Agents::LimitUsage.sole.cost).to eq(BigDecimal("6"))
  ensure
    2.times { release << true }
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "calcola la scadenza dal clock PostgreSQL anche se il clock Rails è discordante" do
    ttl = Agents::PhaseProfile.for(phase).ttl
    database_before = database_now
    result = travel_to(10.years.from_now) do
      described_class.call(
        organization:, host: hosts.first, project:, phase:,
        idempotency_key: SecureRandom.uuid, estimated_cost: 0
      )
    end
    database_after = database_now

    expect(result).to be_ok
    expect(result.value.reservation.expires_at).to be_between(
      database_before + ttl.seconds, database_after + ttl.seconds
    )
  end

  it "calcola la scadenza dal clock PostgreSQL dopo un'attesa sui lock" do
    allow_any_instance_of(described_class).to receive(:after_policies_locked).and_wrap_original do |original|
      ActiveRecord::Base.connection.execute("SELECT pg_sleep(1.1)")
      original.call
    end

    result = described_class.call(
      organization:, host: hosts.first, project:, phase:,
      idempotency_key: SecureRandom.uuid, estimated_cost: 0
    )

    expect(result).to be_ok
    expect(result.value.reservation).to be_granted
    expect(result.value.reservation.expires_at).to be > database_now
    expect(Agents::LimitUsage.sole.runs).to eq(1)
  end

  it "usa l'indice parziale organization/expires_at per il conteggio degli slot attivi" do
    index_name = "index_agents_limit_reservations_active_organization"
    index = ActiveRecord::Base.connection.indexes(:agents_limit_reservations).find { |item| item.name == index_name }

    expect(index.columns).to eq(%w[organization_id expires_at])
    expect(index.where).to include("outcome", "granted")

    connection = ActiveRecord::Base.connection
    relation = Agents::LimitReservation.active.where(organization:)
    plan = ActiveRecord::Base.transaction do
      connection.execute("SET LOCAL enable_seqscan = off")
      connection.select_values("EXPLAIN #{relation.to_sql}").join("\n")
    end
    expect(plan).to include(index_name)
  end

  it "fallisce chiuso se il service account dell'host non vede il progetto" do
    other_project = create(:project, organization:)

    expect do
      result = described_class.call(
        organization:, host: hosts.first, project: other_project, phase:,
        idempotency_key: SecureRandom.uuid, estimated_cost: 0
      )
      expect(result).to be_err
      expect(result.error.code).to eq("R422-AGENT-005")
    end.not_to change(Agents::LimitReservation, :count)
  end

  it "fallisce chiuso su una fase sconosciuta (nessun profilo)" do
    expect do
      result = described_class.call(
        organization:, host: hosts.first, project:, phase: "inesistente",
        idempotency_key: SecureRandom.uuid, estimated_cost: 0
      )
      expect(result).to be_err
      expect(result.error.code).to eq("R422-AGENT-005")
    end.not_to change(Agents::LimitReservation, :count)
  end

  it "fallisce chiuso se un caller interno passa un host già revocato" do
    hosts.first.update!(revoked_at: Time.current)

    expect do
      result = described_class.call(
        organization:, host: hosts.first, project:, phase:,
        idempotency_key: SecureRandom.uuid, estimated_cost: 0
      )
      expect(result).to be_err
      expect(result.error.code).to eq("R422-AGENT-005")
    end.not_to change(Agents::LimitReservation, :count)
  end

  it "rilegge l'host sotto lock e rifiuta una revoca concorrente già committata" do
    ready = Queue.new
    release = Queue.new
    stale_host = Agents::Host.find(hosts.first.id)

    allow_any_instance_of(described_class).to receive(:after_policies_locked).and_wrap_original do |original|
      ready << true
      release.pop
      original.call
    end

    reservation_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(
          organization: Organizations::Organization.find(organization.id),
          host: stale_host, project: Projects::Project.find(project.id),
          phase:, idempotency_key: SecureRandom.uuid, estimated_cost: 0
        )
      end
    end

    Timeout.timeout(5) { ready.pop }
    Agents::Hosts::Revoke.call(host: Agents::Host.find(stale_host.id))
    release << true
    result = Timeout.timeout(10) { reservation_thread.value }

    expect(result).to be_err
    expect(result.error.code).to eq("R422-AGENT-005")
    expect(Agents::LimitReservation).not_to exist
  ensure
    release << true
    if reservation_thread
      reservation_thread.kill if reservation_thread.alive?
      reservation_thread.join
    end
  end

  it "mantiene policy → project tra reservation e cancellazione concorrente del progetto" do
    create(:agent_limit_policy, organization:, project:, max_parallel: 1)
    policies_locked = Queue.new
    release_policies = Queue.new
    destroy_backend = Queue.new
    threads = []

    allow_any_instance_of(described_class).to receive(:after_policies_locked).and_wrap_original do |original|
      policies_locked << true
      release_policies.pop
      original.call
    end

    threads << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(
          organization: Organizations::Organization.find(organization.id),
          host: Agents::Host.find(hosts.first.id), project: Projects::Project.find(project.id),
          phase:, idempotency_key: SecureRandom.uuid, estimated_cost: 0
        )
      end
    end
    Timeout.timeout(5) { policies_locked.pop }

    threads << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        destroy_backend << connection.select_value("SELECT pg_backend_pid()")
        Projects::Destroy.call(project: Projects::Project.find(project.id))
      end
    end
    wait_until_blocked(destroy_backend.pop, threads.second)

    release_policies << true
    reservation_result, destroy_result = Timeout.timeout(10) { threads.map(&:value) }

    expect(reservation_result).to be_ok
    expect(destroy_result).to be_ok
    expect(Projects::Project.where(id: project.id)).not_to exist
    expect(reservation_result.value.reservation.reload.project_id).to be_nil
  ensure
    release_policies << true if release_policies
    threads&.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "tratta come conflitto una fase diversa sotto la stessa idempotency key (Codex P2)" do
    key = SecureRandom.uuid

    first = described_class.call(
      organization:, host: hosts.first, project:, phase: "autopilot",
      idempotency_key: key, estimated_cost: 0
    )
    second = described_class.call(
      organization:, host: hosts.first, project:, phase: "closer_staging",
      idempotency_key: key, estimated_cost: 0
    )

    expect(first).to be_ok
    expect(second).to be_err
    expect(second.error.code).to eq("R409-AGENT-001")
    expect(Agents::LimitReservation.count).to eq(1)
  end

  it "replaya una reservation legacy con phase NULL preservando l'idempotenza (Codex P2)" do
    key = SecureRandom.uuid
    first = described_class.call(
      organization:, host: hosts.first, project:, phase: "autopilot",
      idempotency_key: key, estimated_cost: 0
    )
    expect(first).to be_ok
    # Simula una reservation creata prima di CYAU-91 (colonna phase non ancora popolata).
    first.value.reservation.update_column(:phase, nil)

    replay = described_class.call(
      organization:, host: hosts.first, project:, phase: "autopilot",
      idempotency_key: key, estimated_cost: 0
    )

    expect(replay).to be_ok
    expect(replay.value.replayed).to be(true)
    expect(replay.value.reservation).to eq(first.value.reservation)
  end

  it "rifiuta una idempotency key vuota invece di crearne una valida (Codex P1a)" do
    result = described_class.call(
      organization:, host: hosts.first, project:, phase:,
      idempotency_key: "  ", estimated_cost: 0
    )

    expect(result).to be_err
    expect(result.error.code).to eq("R422-AGENT-005")
    expect(Agents::LimitReservation).not_to exist
  end

  it "nega la reservation se la visibilità dell'host viene revocata prima del check sotto lock (Codex P1)" do
    ready = Queue.new
    release = Queue.new

    allow_any_instance_of(described_class).to receive(:after_policies_locked).and_wrap_original do |original|
      ready << true
      release.pop
      original.call
    end

    reservation_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(
          organization: Organizations::Organization.find(organization.id),
          host: Agents::Host.find(hosts.first.id), project: Projects::Project.find(project.id),
          phase:, idempotency_key: SecureRandom.uuid, estimated_cost: 0
        )
      end
    end

    Timeout.timeout(5) { ready.pop }
    Connections::ProjectMembership.where(account: hosts.first.service_account, project:).delete_all
    release << true
    result = Timeout.timeout(10) { reservation_thread.value }

    expect(result).to be_err
    expect(result.error.code).to eq("R422-AGENT-005")
    expect(Agents::LimitReservation).not_to exist
  ensure
    release << true
    if reservation_thread
      reservation_thread.kill if reservation_thread.alive?
      reservation_thread.join
    end
  end

  def host_seeing_project
    service_account = Accounts::Service::Create.call(organization:, name: "Host SA", project_ids: [ project.id ]).value
    create(:agent_host, organization:, service_account:)
  end

  def wait_until_blocked(backend_pid, thread)
    Timeout.timeout(5) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value(
          "SELECT cardinality(pg_blocking_pids(#{Integer(backend_pid)}))"
        )
        return if blockers.positive?

        raise "La mutazione è terminata prima di attendere il lock PostgreSQL" unless thread.alive?

        Thread.pass
      end
    end
  end

  def database_now
    ActiveRecord::Base.connection.select_value("SELECT clock_timestamp()").in_time_zone
  end
end
