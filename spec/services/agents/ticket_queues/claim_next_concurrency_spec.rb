# frozen_string_literal: true

require "rails_helper"
require "timeout"

# CYRA-588 — concorrenza VERA su PostgreSQL: due thread, due connessioni, la stessa coda. Non basta
# provare che il servizio funziona da solo; la proprietà che il ticket chiede è proprio quella che
# emerge solo quando due postazioni chiedono lavoro nello stesso istante.
RSpec.describe Agents::TicketQueues::ClaimNext, "concorrenza PostgreSQL reale" do
  self.use_transactional_tests = false

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let!(:repository) { create(:github_repository, project:) }
  let!(:reporter) { create(:account) }
  let!(:membership) { create(:membership, organization:, account: reporter) }
  let!(:first_host) { host_ready("runner-1") }
  let!(:second_host) { host_ready("runner-2") }
  let(:high_priority) { create(:ticket_priority, organization:, position: 10) }

  after do
    service_accounts = [ first_host.service_account, second_host.service_account ]
    Ticketing::Ticket.where(project:).find_each(&:destroy!)
    organization.reload.destroy! if organization.persisted?
    service_accounts.each { |account| account.destroy! if account.persisted? }
    reporter.reload.destroy! if reporter.persisted?
  end

  it "consegna due ticket diversi a due postazioni che chiedono insieme" do
    head = create_candidate(priority: high_priority)
    following = create_candidate

    outcomes = claim_together

    expect(outcomes).to all(be_ok)
    expect(outcomes.map { |outcome| outcome.value.ticket.id }).to contain_exactly(head.id, following.id)
    expect(Agents::Lease.where(ticket: [ head, following ]).pluck(:host_id)).to contain_exactly(
      first_host.id, second_host.id
    )
  end

  it "con un solo ticket lavorabile lo consegna a una sola postazione e all'altra dice che non c'è lavoro" do
    only = create_candidate

    outcomes = claim_together

    expect(outcomes).to all(be_ok)
    claimed, empty = outcomes.partition { |outcome| outcome.value }
    expect(claimed.map { |outcome| outcome.value.ticket.id }).to eq([ only.id ])
    expect(empty.size).to eq(1)
    expect(Agents::Lease.where(ticket: only).count).to eq(1)
  end

  # La riga in testa è tenuta da qualcun altro (una modifica del ticket ancora aperta, un altro claim):
  # SKIP LOCKED la salta e serve la successiva. Senza, la coda intera resterebbe ferma dietro una riga
  # sola — che è il motivo per cui il candidato si prende con FOR UPDATE ... SKIP LOCKED.
  it "salta un candidato tenuto da un'altra transazione invece di aspettarlo" do
    head = create_candidate(priority: high_priority)
    following = create_candidate
    holding = Queue.new
    release = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Ticketing::Ticket.transaction do
          Ticketing::Ticket.lock.find(head.id)
          holding << true
          release.pop
        end
      end
    end

    Timeout.timeout(5) { holding.pop }
    outcome = Timeout.timeout(10) { claim(first_host, "run-skip") }

    expect(outcome).to be_ok
    expect(outcome.value.ticket.id).to eq(following.id)
  ensure
    release << true if release
    holder&.join(5)
  end

  def claim_together
    ready = Queue.new
    go = Queue.new
    threads = [ first_host, second_host ].map.with_index do |host, index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          go.pop
          claim(Agents::Host.find(host.id), "run-parallel-#{index}")
        end
      end
    end

    Timeout.timeout(5) { threads.size.times { ready.pop } }
    threads.size.times { go << true }
    Timeout.timeout(20) { threads.map(&:value) }
  ensure
    threads&.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  def claim(host, run_id)
    described_class.call(
      organization: Organizations::Organization.find(organization.id),
      project_key: project.key,
      host:,
      params: { host_id: host.id, run_id: }
    )
  end

  def create_candidate(priority: nil)
    attributes = { organization:, project:, reporter:, reviewer: reporter }
    attributes[:priority] = priority if priority
    create(:ticket, :agent_workable, **attributes, with_agent_workflow: true)
  end

  # ProjectScope host-only: la visibilità sul progetto è del service account dell'host, che l'Attempt
  # host-first esige anche membro dell'organizzazione (tenant_integrity), come lo rende Register.
  def host_ready(hostname)
    service_account = create(:account, :service).tap do |account|
      create(:membership, organization:, account:)
      create(:project_membership, account:, project:)
    end
    create(:agent_host, organization:, hostname:, service_account:, last_heartbeat_at: Time.current,
                        repositories: [ project.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end
end
