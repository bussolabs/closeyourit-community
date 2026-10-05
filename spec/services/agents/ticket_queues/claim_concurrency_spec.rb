# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Agents::TicketQueues::Claim, "concorrenza PostgreSQL reale" do
  self.use_transactional_tests = false

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let!(:repository) { create(:github_repository, project:) }
  let!(:reporter) { create(:account) }
  let!(:membership) { create(:membership, organization:, account: reporter) }
  let!(:ticket) { create(:ticket, :agent_workable, organization:, project:, reporter:, reviewer: reporter, with_agent_workflow: true) }
  let!(:policy) { create(:agent_limit_policy, organization:, max_daily_cost: 10) }
  # ProjectScope host-only (CYAU-95): la visibilità sul progetto è del service account dell'host. L'Attempt
  # host-first (CYAU-82) esige inoltre che il SA sia membro dell'org (tenant_integrity), come lo rende Register.
  let!(:host_service_account) do
    create(:account, :service).tap do |account|
      create(:membership, organization:, account:)
      create(:project_membership, account:, project:)
    end
  end
  let!(:host) do
    create(:agent_host, organization:, service_account: host_service_account, last_heartbeat_at: Time.current,
                        repositories: [ project.key ], runtimes: [ { "name" => "claude", "present" => true } ])
  end
  let(:selection_token) do
    Agents::TicketQueues::Selection.issue(ticket:, host:, estimated_cost: "1.0000")
  end

  after do
    host_sa = host_service_account
    ticket.destroy! if ticket.persisted?
    organization.reload.destroy! if organization.persisted?
    host_sa.destroy! if host_sa.persisted?
    reporter.reload.destroy! if reporter.persisted?
  end

  it "annulla reservation e usage se il candidato cambia prima del lock finale" do
    reserved = Queue.new
    release = Queue.new
    claim_thread = nil

    allow_any_instance_of(described_class).to receive(:after_limit_reserved).and_wrap_original do |original, value|
      reserved << true
      release.pop
      original.call(value)
    end

    claim_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(
          organization: Organizations::Organization.find(organization.id),
          host: Agents::Host.find(host.id),
          selection_token:,
          params: { host_id: host.id, run_id: "race-run", ttl_seconds: 3600 }
        )
      end
    end

    Timeout.timeout(5) { reserved.pop }
    ticket.update!(title: "Candidato cambiato durante il claim")
    release << true
    result = Timeout.timeout(10) { claim_thread.value }

    expect(result).to be_err
    expect(result.error.code).to eq("R409-QUEUE-001")
    expect(Agents::LimitReservation).not_to exist
    expect(Agents::LimitUsage).not_to exist
    expect(Agents::Lease).not_to exist
  ensure
    release << true if release
    if claim_thread
      claim_thread.kill if claim_thread.alive?
      claim_thread.join
    end
  end

  it "fallisce chiuso e annulla il budget se l'host viene revocato dopo la reservation" do
    allow_any_instance_of(described_class).to receive(:after_limit_reserved).and_wrap_original do |original, value|
      Agents::Host.where(id: host.id).update_all(revoked_at: Time.current)
      original.call(value)
    end

    result = described_class.call(
      organization:,
      host:,
      selection_token:,
      params: { host_id: host.id, run_id: "revoked-host-run", ttl_seconds: 3600 }
    )

    expect(result).to be_err
    expect(result.error.code).to eq("R404-QUEUE-001")
    expect(Agents::LimitReservation).not_to exist
    expect(Agents::LimitUsage).not_to exist
    expect(Agents::Lease).not_to exist
    expect(host.reload).not_to be_revoked
  end

  it "annulla anche una reservation negata se il candidato diventa stale prima del lock finale" do
    policy.update!(max_daily_cost: nil, max_daily_runs: 0)
    reserved = Queue.new
    release = Queue.new
    claim_thread = nil

    allow_any_instance_of(described_class).to receive(:after_limit_reserved).and_wrap_original do |original, value|
      reserved << true
      release.pop
      original.call(value)
    end

    claim_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(
          organization: Organizations::Organization.find(organization.id),
          host: Agents::Host.find(host.id),
          selection_token:,
          params: { host_id: host.id, run_id: "denied-stale-run", ttl_seconds: 3600 }
        )
      end
    end

    Timeout.timeout(5) { reserved.pop }
    ticket.update!(title: "Candidato cambiato dopo una decisione negata")
    release << true
    result = Timeout.timeout(10) { claim_thread.value }

    expect(result).to be_err
    expect(result.error.code).to eq("R409-QUEUE-001")
    expect(Agents::LimitReservation).not_to exist
    expect(Agents::LimitUsage).not_to exist
    expect(Agents::Lease).not_to exist
  ensure
    release << true if release
    if claim_thread
      claim_thread.kill if claim_thread.alive?
      claim_thread.join
    end
  end


  # CYRA-623 — il ricontrollo dei prerequisiti al momento della presa in carico NON prende righe in
  # lock, e non è una scelta di stile: il dispatch locka in ordine policy→host→progetto→ticket, il
  # cancello per id ordinati. Prendere qui il lock sui prerequisiti creerebbe la coppia inversa — due
  # transazioni che si aspettano a vicenda — e un deadlock non si scopre in prova: si scopre in
  # produzione, a code ferme.
  it "il ricontrollo dei prerequisiti non aspetta chi tiene bloccata la riga del prerequisito" do
    fatto = create(:ticket_status, :done, organization:)
    # Il reporter è quello del file, non uno nuovo: gli account non appartengono all'organizzazione e
    # non se ne vanno con la sua cascata. Uno lasciato indietro fa collidere la sequenza delle email
    # nelle prove che girano dopo, e il rosso compare in un file che non c'entra niente.
    blocker = create(:ticket, organization:, project:, status: fatto, reporter:, reviewer: reporter, with_agent_workflow: true)
    create(:ticket_dependency, ticket:, blocker:)
    firmato = selection_token
    pronto = Queue.new
    libera = Queue.new

    tenuta = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Ticketing::Ticket.transaction do
          Ticketing::Ticket.where(id: blocker.id).lock.load
          pronto << true
          libera.pop
        end
      end
    end
    Timeout.timeout(5) { pronto.pop }

    esito = Timeout.timeout(10) do
      described_class.call(organization:, host:, selection_token: firmato,
                           params: { host_id: host.id, run_id: "run-prereq", ttl_seconds: 3600 })
    end

    expect(esito).to be_ok
  ensure
    libera << true if libera
    tenuta&.join(5)
    # Prerequisito e stato se ne vanno con l'organizzazione, che l'`after` del file distrugge: toccarli
    # qui fallirebbe, perché sono ancora referenziati dalle righe che quella cascata porta via.
  end

  # I test "timeout stale sotto lock" e "update timeout attende il lock" sono stati rimossi (CYAU-91):
  # con il TTL per-fase (PhaseProfile, fisso) non esiste più una TOCTOU sul timeout_seconds dell'agente.
  # Il mismatch del TTL (client ≠ profilo) è ora rilevato a monte in Claim#authoritative_ttl? e coperto
  # dal request spec agent_ticket_queue_claims.
end
