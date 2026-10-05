# frozen_string_literal: true

require "rails_helper"
require "timeout"

# CYRA-729 · Scenario 1 — due macchine chiedono lo stesso ticket nello stesso istante.
#
# La presa in carico aveva prove sulle sue reazioni laterali (budget annullato, host revocato,
# prerequisito bloccato da un altro), ma non sul caso che la motiva: due postazioni che partono
# insieme sullo stesso ticket. È il difetto che costa di più — due macchine che lavorano lo stesso
# lavoro non si vedono a vicenda, e il doppio lavoro si scopre solo alla consegna.
#
# Serve PostgreSQL vero e connessioni separate: la mutua esclusione la fa il database, non il timing
# dei thread. Niente transactional tests.
RSpec.describe Agents::TicketQueues::Claim, "due macchine sullo stesso ticket" do
  self.use_transactional_tests = false

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let!(:repository) { create(:github_repository, project:) }
  let!(:reporter) { create(:account) }
  let!(:membership) { create(:membership, organization:, account: reporter) }
  let!(:ticket) { create(:ticket, :agent_workable, organization:, project:, reporter:, reviewer: reporter, with_agent_workflow: true) }
  let!(:policy) { create(:agent_limit_policy, organization:, max_daily_cost: 10) }

  # Due postazioni gemelle: stesso progetto visibile, stesso runtime, stessa organizzazione. L'unica
  # differenza è chi arriva prima al lock del progetto — cioè nessuna differenza decisa da noi.
  let(:postazioni) { [ registra_host("uno"), registra_host("due") ] }
  let(:prima) { postazioni.first }
  let(:seconda) { postazioni.second }

  def registra_host(nome)
    service_account = create(:account, :service).tap do |account|
      create(:membership, organization:, account:)
      create(:project_membership, account:, project:)
    end
    create(:agent_host, organization:, service_account:, hostname: "host-#{nome}",
                        last_heartbeat_at: Time.current, repositories: [ project.key ],
                        runtimes: [ { "name" => "claude", "present" => true } ])
  end

  def firma(host)
    Agents::TicketQueues::Selection.issue(ticket: ticket.reload, host:, estimated_cost: "1.0000")
  end

  def prendi(host, token, run_id)
    described_class.call(
      organization: Organizations::Organization.find(organization.id),
      host: Agents::Host.find(host.id),
      selection_token: token,
      params: { host_id: host.id, run_id:, ttl_seconds: Agents::PhaseProfile.fetch("triage").ttl }
    )
  end

  after do
    service_accounts = organization.persisted? ? organization.agent_hosts.filter_map(&:service_account) : []
    ticket.destroy! if ticket.persisted?
    organization.reload.destroy! if organization.persisted?
    Accounts::Account.where(id: service_accounts.map(&:id)).destroy_all
    reporter.reload.destroy! if reporter.persisted?
  end

  it "lo consegna a una sola macchina e all'altra spiega perché non è più sua" do
    token = { prima.id => firma(prima), seconda.id => firma(seconda) }
    aspettano = 0
    mutex = Mutex.new
    barriera = ConditionVariable.new
    threads = []

    # Rendezvous PRIMA della transazione: entrambe superano il preflight (il ticket è ancora libero
    # per tutte e due) e partono insieme verso il lock. Chi vince lo decide il database.
    allow_any_instance_of(Agents::TicketQueues::CandidateSnapshot).to receive(:load).and_wrap_original do |original, *args|
      contesto = original.call(*args)
      mutex.synchronize do
        aspettano += 1
        barriera.broadcast
        barriera.wait(mutex) while aspettano < 2
      end
      contesto
    end

    threads = postazioni.map do |host|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          prendi(host, token.fetch(host.id), "run-#{host.id}")
        end
      end
    end
    esiti = Timeout.timeout(20) { threads.map(&:value) }

    vincitrice = esiti.find(&:ok?)
    perdente = esiti.find(&:err?)
    expect(esiti.count(&:ok?)).to eq(1)
    # Il rifiuto ha un codice, non è un errore generico: chi lo riceve sa che la selezione è passata
    # di mano e che deve chiederne una nuova, non che qualcosa si è rotto.
    expect(perdente.error).to have_attributes(code: "R409-QUEUE-001", status: :conflict)

    # Un solo lucchetto, un solo tentativo, una sola fase avviata: la prova che il doppio lavoro non
    # è nato nemmeno per un istante.
    expect(Agents::Lease.where(ticket:).sole.host_id).to eq(vincitrice.value.lease.host_id)
    expect(Agents::Attempt.where(workflow: ticket.agent_workflow).sole.id).to eq(vincitrice.value.attempt.id)
    expect(ticket.agent_workflow.reload.triage_by_host_id).to eq(vincitrice.value.lease.host_id)
  ensure
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "non lascia alla perdente né budget né tentativo appesi" do
    token = { prima.id => firma(prima), seconda.id => firma(seconda) }
    aspettano = 0
    mutex = Mutex.new
    barriera = ConditionVariable.new
    threads = []

    allow_any_instance_of(Agents::TicketQueues::CandidateSnapshot).to receive(:load).and_wrap_original do |original, *args|
      contesto = original.call(*args)
      mutex.synchronize do
        aspettano += 1
        barriera.broadcast
        barriera.wait(mutex) while aspettano < 2
      end
      contesto
    end

    threads = postazioni.map do |host|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          prendi(host, token.fetch(host.id), "run-#{host.id}")
        end
      end
    end
    esiti = Timeout.timeout(20) { threads.map(&:value) }
    vincitrice = esiti.find(&:ok?)
    perdente_id = (postazioni.map(&:id) - [ vincitrice.value.lease.host_id ]).sole

    # Il budget della perdente torna indietro col rollback del savepoint: se restasse scritto, quella
    # macchina pagherebbe per sempre un lavoro che non ha nemmeno cominciato. Il consumo è aggregato
    # per policy, quindi si legge sul totale: una presa in carico contata, non due.
    expect(Agents::LimitReservation.where(host_id: perdente_id)).not_to exist
    expect(Agents::LimitUsage.sum(:runs)).to eq(1)
    expect(Agents::Attempt.where(host_id: perdente_id)).not_to exist
    expect(Agents::Lease.where(host_id: perdente_id)).not_to exist
  ensure
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  # La seconda metà dello Scenario 1: perdere non vuol dire perdere per sempre. Il ticket non è
  # sigillato dalla macchina che l'ha vinto — quando quella lascia il campo, torna prendibile.
  it "il ticket non resta bloccato per sempre: chi ha perso lo riprende quando la fase si riapre" do
    # Entrambe hanno in mano una selezione firmata quando il ticket era ancora libero: è la
    # situazione vera, la coda le ha servite tutte e due prima che una arrivasse a prenderlo.
    token_seconda = firma(seconda)
    vinta = prendi(prima, firma(prima), "run-vincente")
    expect(vinta).to be_ok

    persa = prendi(seconda, token_seconda, "run-perdente")
    expect(persa.error).to have_attributes(code: "R409-QUEUE-001", status: :conflict)

    # La macchina che aveva vinto si ferma a metà: rilascia il lucchetto e il recupero riapre la fase
    # avviata e mai conclusa. È lo stesso percorso del controllo periodico degli orfani.
    Agents::Leases::Release.call(
      organization:, holder: Agents::Leases::Holder.host(prima), ticket_reference: ticket.code,
      params: { ticket: ticket.code, host_id: prima.id, run_id: "run-vincente" }
    )
    Agents::Attempt.where(host: prima).update_all(status: Agents::Attempt.statuses[:stale])
    expect(ticket.agent_workflow.reload.reopen_execution_phase!("triage")).to be true

    ripresa = prendi(seconda, firma(seconda), "run-ripresa")

    expect(ripresa).to be_ok
    expect(Agents::Lease.where(ticket:).sole.host_id).to eq(seconda.id)
    expect(ticket.agent_workflow.reload.triage_by_host_id).to eq(seconda.id)
  end

  # Stessa macchina, stessa richiesta, due volte: è il retry di rete, non una seconda presa in
  # carico. Deve tornare lo stesso lucchetto e lo stesso tentativo, non un doppione.
  it "un retry della stessa macchina con lo stesso run torna sullo stesso lavoro" do
    token = firma(prima)
    prima_volta = prendi(prima, token, "run-idempotente")
    seconda_volta = prendi(prima, token, "run-idempotente")

    expect(prima_volta).to be_ok
    expect(seconda_volta).to be_ok
    expect(seconda_volta.value.attempt.id).to eq(prima_volta.value.attempt.id)
    expect(seconda_volta.value.lease.id).to eq(prima_volta.value.lease.id)
    expect(seconda_volta.value.fresh_acquisition).to be false
    expect(Agents::Lease.where(ticket:).count).to eq(1)
    expect(Agents::Attempt.where(workflow: ticket.agent_workflow).count).to eq(1)
  end
end
