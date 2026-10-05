# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Agents::TicketQueues::Defer, "concorrenza PostgreSQL reale" do
  self.use_transactional_tests = false

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let!(:repository) { create(:github_repository, project:) }
  let!(:reporter) { create(:account) }
  let!(:membership) { create(:membership, organization:, account: reporter) }
  let!(:ticket) { create(:ticket, :agent_workable, organization:, project:, reporter:, reviewer: reporter, with_agent_workflow: true) }
  # ProjectScope host-only (CYAU-95): la visibilità sul progetto è del service account dell'host (il factory
  # project_membership gli conferisce anche la membership org, richiesta dal tenant_integrity dell'Attempt).
  let!(:host_service_account) do
    create(:account, :service).tap { |account| create(:project_membership, account:, project:) }
  end
  let!(:host) do
    create(:agent_host, organization:, service_account: host_service_account, last_heartbeat_at: Time.current,
                        repositories: [ project.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end

  after do
    host_sa = host_service_account
    organization.reload.destroy! if organization.persisted?
    host_sa.destroy! if host_sa.persisted?
    reporter.reload.destroy! if reporter.persisted?
  end

  it "con due token distinti crea un solo defer e non estende retry_at" do
    tokens = [
      Agents::TicketQueues::Selection.issue(ticket:, host:),
      travel(1.second) { Agents::TicketQueues::Selection.issue(ticket:, host:) }
    ]
    expect(tokens.uniq.length).to eq(2)
    ready = Queue.new
    start = Queue.new

    threads = tokens.map do |token|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          defer(token:)
        end
      end
    end
    2.times { Timeout.timeout(5) { ready.pop } }
    2.times { start << true }
    results = threads.map { |thread| Timeout.timeout(10) { thread.value } }

    expect(results).to all(be_ok)
    expect(results.map { |result| result.value.replayed }).to contain_exactly(false, true)
    expect(results.map { |result| result.value.deferral.id }.uniq.one?).to be(true)
    expect(Agents::TicketQueueDeferral.where(host:, ticket:).count).to eq(1)
    expect(results.map { |result| result.value.deferral.retry_at }.uniq.one?).to be(true)
  ensure
    threads&.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "fa vincere defer già locked e impedisce il claim successivo" do
    locked = Queue.new
    release = Queue.new
    token = Agents::TicketQueues::Selection.issue(ticket:, host:)
    allow_any_instance_of(described_class).to receive(:after_candidate_locked).and_wrap_original do |original, context|
      locked << true
      release.pop
      original.call(context)
    end

    defer_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { defer(token:) }
    end
    Timeout.timeout(5) { locked.pop }
    claim_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { claim(token:) }
    end
    release << true
    defer_result = Timeout.timeout(10) { defer_thread.value }
    claim_result = Timeout.timeout(10) { claim_thread.value }

    expect(defer_result).to be_ok
    expect(claim_result).to be_err
    expect(claim_result.error.code).to eq("R409-QUEUE-003")
    expect(Agents::TicketQueueDeferral.where(host:, ticket:).count).to eq(1)
    expect(Agents::Lease).not_to exist
    expect(Agents::LimitReservation).not_to exist
  ensure
    release << true if release
    [ defer_thread, claim_thread ].compact.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "fa vincere il claim già locked e impedisce il defer successivo" do
    reserved = Queue.new
    release = Queue.new
    token = Agents::TicketQueues::Selection.issue(ticket:, host:)
    allow_any_instance_of(Agents::TicketQueues::Claim).to receive(:after_limit_reserved).and_wrap_original do |original, value|
      reserved << true
      release.pop
      original.call(value)
    end

    claim_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { claim(token:) }
    end
    Timeout.timeout(5) { reserved.pop }
    defer_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { defer(token:) }
    end
    release << true
    claim_result = Timeout.timeout(10) { claim_thread.value }
    defer_result = Timeout.timeout(10) { defer_thread.value }

    expect(claim_result).to be_ok
    expect(defer_result).to be_err
    expect(defer_result.error.code).to eq("R409-QUEUE-001")
    expect(Agents::Lease.where(ticket:).count).to eq(1)
    expect(Agents::TicketQueueDeferral).not_to exist
  ensure
    release << true if release
    [ claim_thread, defer_thread ].compact.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "non serializza Defer sull'intera organization mentre Claim trattiene le policy" do
    policies_locked = Queue.new
    release_claim = Queue.new
    token = Agents::TicketQueues::Selection.issue(ticket:, host:)
    allow_any_instance_of(Agents::Limits::Reserve).to receive(:after_policies_locked).and_wrap_original do |original|
      policies_locked << true
      release_claim.pop
      original.call
    end

    claim_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { claim(token:) }
    end
    Timeout.timeout(5) { policies_locked.pop }
    defer_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        defer(token:)
      end
    end
    defer_result = Timeout.timeout(10) { defer_thread.value }
    release_claim << true
    claim_result = Timeout.timeout(10) { claim_thread.value }

    expect(defer_result).to be_ok
    expect(claim_result).to be_err
    expect(claim_result.error.code).to eq("R409-QUEUE-003")
    expect(Agents::TicketQueueDeferral.where(host:, ticket:).count).to eq(1)
    expect(Agents::Lease).not_to exist
    expect(Agents::LimitReservation).not_to exist
  ensure
    release_claim << true if release_claim
    [ claim_thread, defer_thread ].compact.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  private

  def defer(token:)
    described_class.call(
      organization: Organizations::Organization.find(organization.id),
      host: Agents::Host.find(host.id),
      selection_token: token,
      params: { host_id: host.id, reason: "temporary_failure" }
    )
  end

  def claim(token:)
    Agents::TicketQueues::Claim.call(
      organization: Organizations::Organization.find(organization.id),
      host: Agents::Host.find(host.id),
      selection_token: token,
      params: { host_id: host.id, run_id: "race-run", ttl_seconds: 3600 }
    )
  end
end
