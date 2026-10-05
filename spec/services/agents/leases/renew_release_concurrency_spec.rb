# frozen_string_literal: true

require "rails_helper"
require "timeout"

# CYRA-729 — il rinnovo e la memoria del rilascio, con due macchine in corsa.
#
# La presa del lucchetto aveva già le sue prove concorrenti; il RINNOVO no, e il rinnovo è la parte
# che tiene in vita una lavorazione lunga: se due richieste sullo stesso lucchetto si pestassero, o
# una macchina si vedrebbe scadere il lavoro sotto le mani, o due lo terrebbero insieme.
#
# E poi c'è la memoria del rilascio, che è la trappola vera: la memoria è per LAVORAZIONE, non per
# macchina. Una macchina che rilascia e ripresenta lo STESSO nome di lavorazione resta fuori per
# sempre — non è un difetto, è la difesa contro il ritorno di un lavoro già chiuso. Ma va scritto in
# una prova, perché chi legge il codice per la prima volta lo scambia per un ticket che si è
# incantato.
#
# Serve PostgreSQL vero e connessioni separate: niente transactional tests.
RSpec.describe Agents::Leases::Renew, "rinnovo e memoria del rilascio in concorrenza" do
  self.use_transactional_tests = false

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let(:reporter) do
    nonce = SecureRandom.hex(8)
    create(:account, email: "renew-concurrency-#{nonce}@example.com", handle: "renew_concurrency_#{nonce}")
  end
  let(:ticket) { create(:ticket, organization:, project:, reporter:, reviewer: reporter) }
  let(:hosts) { create_list(:agent_host, 2, organization:) }
  let(:titolare) { hosts.first }
  let(:rivale) { hosts.second }

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
    leftover_accounts = []
    if organization.persisted?
      leftover_accounts += organization.agent_hosts.filter_map(&:service_account)
      leftover_accounts += organization.accounts.to_a
    end
    leftover_accounts << reporter
    ticket.destroy! if ticket.persisted?
    organization.reload.destroy! if organization.persisted?
    Accounts::Account.where(id: leftover_accounts.map(&:id).uniq).destroy_all
  end

  def rinnova(host, run_id, ttl_seconds: 60)
    described_class.call(
      organization: Organizations::Organization.find(organization.id),
      holder: Agents::Leases::Holder.host(Agents::Host.find(host.id)),
      ticket_reference: ticket.code,
      params: { ticket: ticket.code, host_id: host.id, run_id:, ttl_seconds: }
    )
  end

  def prendi(host, run_id, ttl_seconds: 60)
    Agents::Leases::Acquire.call(
      organization: Organizations::Organization.find(organization.id),
      holder: Agents::Leases::Holder.host(Agents::Host.find(host.id)),
      ticket_reference: ticket.code,
      params: { ticket: ticket.code, host_id: host.id, run_id:, agent: "triage", ttl_seconds: }
    )
  end

  def rilascia(host, run_id)
    Agents::Leases::Release.call(
      organization: Organizations::Organization.find(organization.id),
      holder: Agents::Leases::Holder.host(Agents::Host.find(host.id)),
      ticket_reference: ticket.code,
      params: { ticket: ticket.code, host_id: host.id, run_id: }
    )
  end

  # Rendezvous sul PRIMO lock della catena (host → ticket → lease): due richieste superano insieme la
  # validazione e corrono verso il database, che le serializza. Fermarle più avanti non funzionerebbe
  # per due richieste della stessa macchina — la seconda resterebbe in attesa della riga host e non
  # arriverebbe mai al punto d'incontro.
  def in_parallelo(&blocco)
    aspettano = 0
    mutex = Mutex.new
    barriera = ConditionVariable.new

    allow_any_instance_of(Agents::Host).to receive(:lock!).and_wrap_original do |original, *args|
      mutex.synchronize do
        aspettano += 1
        barriera.broadcast
        barriera.wait(mutex) while aspettano < 2
      end
      original.call(*args)
    end

    blocco.call
  end

  describe "rinnovo con la lavorazione che tiene il lucchetto" do
    it "due rinnovi simultanei della stessa lavorazione la lasciano titolare, una riga sola" do
      create(:agent_lease, organization:, ticket:, host: titolare, run_id: "run-titolare",
                           expires_at: 30.seconds.from_now)
      threads = []

      in_parallelo do
        threads = 2.times.map do
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection { rinnova(titolare, "run-titolare") }
          end
        end
      end
      esiti = Timeout.timeout(15) { threads.map(&:value) }

      expect(esiti).to all(be_ok)
      lease = Agents::Lease.where(ticket:).sole
      expect(lease).to have_attributes(host_id: titolare.id, run_id: "run-titolare")
      # La finestra si è spostata in avanti: un rinnovo che lasciasse la scadenza dov'era farebbe
      # morire sotto le mani una lavorazione che sta chiedendo proprio di restare viva.
      expect(lease.expires_at).to be > 30.seconds.from_now
    ensure
      threads.each do |thread|
        thread.kill if thread.alive?
        thread.join
      end
    end

    it "rinnova solo chi tiene il lucchetto e dice all'altra macchina di chi è" do
      create(:agent_lease, organization:, ticket:, host: titolare, run_id: "run-titolare",
                           expires_at: 30.seconds.from_now)
      threads = []

      in_parallelo do
        threads = [
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection { rinnova(titolare, "run-titolare") }
          end,
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection { rinnova(rivale, "run-rivale") }
          end
        ]
      end
      rinnovato, rifiutato = Timeout.timeout(15) { threads.map(&:value) }

      expect(rinnovato).to be_ok
      expect(rifiutato.error).to have_attributes(code: "R409-LEASE-001", status: :conflict)
      # Nel corpo del rifiuto c'è chi tiene il ticket: il client lo dice a chi guarda senza dover
      # fare una seconda domanda.
      expect(rifiutato.error.details.dig(:holder, :host_id)).to eq(titolare.id)
      expect(Agents::Lease.where(ticket:).sole.host_id).to eq(titolare.id)
    ensure
      threads.each do |thread|
        thread.kill if thread.alive?
        thread.join
      end
    end

    # Stesso host, nome di lavorazione diverso: è un run nuovo, non il titolare. Vale il conflitto,
    # non l'idempotenza — altrimenti una macchina ripartita da zero prolungherebbe il lavoro della
    # propria istanza precedente.
    it "non riconosce come titolare la stessa macchina con un'altra lavorazione" do
      create(:agent_lease, organization:, ticket:, host: titolare, run_id: "run-titolare",
                           expires_at: 30.seconds.from_now)

      esito = rinnova(titolare, "run-successivo")

      expect(esito.error).to have_attributes(code: "R409-LEASE-001", status: :conflict)
      expect(esito.error.details.dig(:holder, :run_id)).to eq("run-titolare")
    end

    it "non resuscita un lucchetto rilasciato mentre il rinnovo era in viaggio" do
      create(:agent_lease, organization:, ticket:, host: titolare, run_id: "run-titolare",
                           expires_at: 5.minutes.from_now)
      tombstone_scritta = Queue.new
      rinnovo_in_coda = Queue.new
      threads = []

      allow(Agents::Leases::Tombstone).to receive(:record!).and_wrap_original do |original, **kwargs|
        tombstone = original.call(**kwargs)
        if Thread.current[:operazione] == :release
          tombstone_scritta << true
          rinnovo_in_coda.pop
        end
        tombstone
      end
      allow_any_instance_of(Agents::Host).to receive(:lock!).and_wrap_original do |original, *args|
        rinnovo_in_coda << true if Thread.current[:operazione] == :renew
        original.call(*args)
      end

      threads << Thread.new do
        Thread.current[:operazione] = :release
        ActiveRecord::Base.connection_pool.with_connection { rilascia(titolare, "run-titolare") }
      end
      Timeout.timeout(5) { tombstone_scritta.pop }

      threads << Thread.new do
        Thread.current[:operazione] = :renew
        ActiveRecord::Base.connection_pool.with_connection { rinnova(titolare, "run-titolare") }
      end
      rilasciato, rinnovato = Timeout.timeout(15) { threads.map(&:value) }

      expect(rilasciato).to be_ok
      expect(rinnovato.error).to have_attributes(code: "R404-LEASE-002", status: :not_found)
      expect(Agents::Lease.where(ticket:)).not_to exist
    ensure
      rinnovo_in_coda << true if defined?(rinnovo_in_coda)
      threads.each do |thread|
        thread.kill if thread.alive?
        thread.join
      end
    end
  end

  describe "la memoria del rilascio" do
    # Il caso che il ticket chiama «bloccato per sempre»: il nome della lavorazione resta lo stesso,
    # e quel nome è già stato chiuso. Non è il ticket a essere incantato — è quella lavorazione a
    # essere finita, e riproporla è il ritorno di un lavoro già consegnato.
    it "una macchina che ripresenta lo stesso nome di lavorazione resta fuori per sempre" do
      expect(prendi(titolare, "run-stabile")).to be_ok
      expect(rilascia(titolare, "run-stabile")).to be_ok

      3.times do
        esito = prendi(titolare, "run-stabile")

        expect(esito.error).to have_attributes(code: "R409-LEASE-002", status: :conflict)
      end
      expect(Agents::Lease.where(ticket:)).not_to exist
    end

    # E la metà che salva il ticket: un nome nuovo entra subito. La memoria chiude UNA lavorazione,
    # non il ticket — chi riparte cambiando nome riprende il lavoro senza aspettare niente.
    it "la stessa macchina con un nome nuovo riprende il ticket subito" do
      expect(prendi(titolare, "run-stabile")).to be_ok
      expect(rilascia(titolare, "run-stabile")).to be_ok

      ripresa = prendi(titolare, "run-successivo")

      expect(ripresa).to be_ok
      expect(Agents::Lease.where(ticket:).sole).to have_attributes(host_id: titolare.id,
                                                                   run_id: "run-successivo")
    end

    # La memoria non è un lucchetto: mentre il rilascio la rende durevole, chi porta un nome diverso
    # deve poter entrare. Se la memoria chiudesse il ticket invece della lavorazione, questa macchina
    # resterebbe fuori — ed è il ticket bloccato per sempre, quello vero.
    it "non chiude il ticket a chi arriva con un nome diverso mentre il rilascio si rende durevole" do
      create(:agent_lease, organization:, ticket:, host: titolare, run_id: "run-titolare",
                           expires_at: 5.minutes.from_now)
      tombstone_scritta = Queue.new
      presa_in_coda = Queue.new
      threads = []

      allow(Agents::Leases::Tombstone).to receive(:record!).and_wrap_original do |original, **kwargs|
        tombstone = original.call(**kwargs)
        if Thread.current[:operazione] == :release
          tombstone_scritta << true
          presa_in_coda.pop
        end
        tombstone
      end
      allow_any_instance_of(Agents::Host).to receive(:lock!).and_wrap_original do |original, *args|
        presa_in_coda << true if Thread.current[:operazione] == :acquire
        original.call(*args)
      end

      threads << Thread.new do
        Thread.current[:operazione] = :release
        ActiveRecord::Base.connection_pool.with_connection { rilascia(titolare, "run-titolare") }
      end
      Timeout.timeout(5) { tombstone_scritta.pop }

      threads << Thread.new do
        Thread.current[:operazione] = :acquire
        ActiveRecord::Base.connection_pool.with_connection { prendi(rivale, "run-rivale") }
      end
      rilasciato, presa = Timeout.timeout(15) { threads.map(&:value) }

      expect(rilasciato).to be_ok
      expect(presa).to be_ok
      expect(Agents::Lease.where(ticket:).sole).to have_attributes(host_id: rivale.id, run_id: "run-rivale")
      expect(Agents::Leases::Tombstone.where(ticket:, host: titolare, run_id: "run-titolare")).to exist
    ensure
      presa_in_coda << true if defined?(presa_in_coda)
      threads.each do |thread|
        thread.kill if thread.alive?
        thread.join
      end
    end
  end
end
