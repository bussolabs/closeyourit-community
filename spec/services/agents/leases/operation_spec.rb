# frozen_string_literal: true

require "rails_helper"

# CYRA-729 — il confine condiviso dalle tre porte del lucchetto: prendere, rinnovare, rilasciare.
#
# Le tre operazioni ereditano lo stesso confine, e questo è il punto: la stessa richiesta sbagliata
# deve ricevere la stessa risposta da tutte e tre. Finora era provato quasi solo su «prendere» —
# quindi un `require_ttl:` dimenticato in una sottoclasse, o un controllo del titolare saltato in
# un'altra, sarebbe passato liscio: la porta rimasta indietro non ha una prova che la guardi.
#
# Qui la stessa richiesta entra da tutte e tre le porte e si verifica che rispondano insieme.
RSpec.describe Agents::Leases::Operation, "il confine condiviso dalle tre porte" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let(:ticket) { create(:ticket, organization:, project:) }
  let(:service_account) do
    Accounts::Service::Create.call(organization:, name: "Lease host", handle: "lease_host", project_ids: [ project.id ]).value
  end
  let(:host) { create(:agent_host, organization:, service_account:) }
  let(:altro_host) { create(:agent_host, organization:) }

  # Ogni porta ha il suo insieme minimo di campi: rilasciare non chiede un TTL, rinnovare non chiede
  # un'identità di lavoro. Il resto del confine è identico, ed è quello che si verifica.
  def da_ogni_porta(params)
    {
      prendere: Agents::Leases::Acquire.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: ticket.code, params:
      ),
      rinnovare: Agents::Leases::Renew.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: ticket.code,
        params: params.except(:agent)
      ),
      rilasciare: Agents::Leases::Release.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: ticket.code,
        params: params.except(:agent, :ttl_seconds)
      )
    }
  end

  let(:params_validi) do
    { ticket: ticket.code, host_id: host.id, run_id: "run-42", agent: "triage", ttl_seconds: 60 }
  end

  describe "host project authority" do
    it "denies acquisition and renewal when the host has no service account" do
      host.update!(service_account: nil)
      params = { ticket: ticket.code, host_id: host.id, run_id: "no-account", agent: "triage", ttl_seconds: 60 }
      [ Agents::Leases::Acquire, Agents::Leases::Renew ].each do |operation|
        result = operation.call(organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: ticket.code, params:)
        expect(result.error).to have_attributes(code: "R404-LEASE-001", status: :not_found)
      end
      expect(Agents::Lease.where(ticket:)).not_to exist
    end

    it "denies new work after project access is removed while allowing the owner to release" do
      lease = create(:agent_lease, organization:, ticket:, host:, run_id: "lost-access", expires_at: 5.minutes.from_now)
      service_account.project_memberships.find_by!(project:).destroy!
      params = { ticket: ticket.code, host_id: host.id, run_id: lease.run_id, agent: "triage", ttl_seconds: 60 }
      [ Agents::Leases::Acquire, Agents::Leases::Renew ].each do |operation|
        result = operation.call(organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: ticket.code, params:)
        expect(result.error).to have_attributes(code: "R404-LEASE-001", status: :not_found)
        expect(lease.reload).to be_persisted
      end
      released = Agents::Leases::Release.call(organization:, holder: Agents::Leases::Holder.host(host),
        ticket_reference: ticket.code, params: params.except(:agent, :ttl_seconds))
      expect(released).to be_ok
      expect(Agents::Lease.where(id: lease.id)).not_to exist
      expect(Agents::Leases::Tombstone.where(ticket:, host:, run_id: "lost-access")).to exist
    end
  end

  describe "l'identità di chi bussa" do
    it "nessuna porta accetta un host_id diverso da quello del token" do
      esiti = da_ogni_porta(params_validi.merge(host_id: altro_host.id))

      expect(esiti.values).to all(have_attributes(error: have_attributes(code: "R403-LEASE-001",
                                                                        status: :forbidden)))
      expect(Agents::Lease.count).to eq(0)
    end

    it "nessuna porta accetta un host_id assente o vuoto" do
      [ nil, "", "   " ].each do |host_id|
        esiti = da_ogni_porta(params_validi.merge(host_id:))

        expect(esiti.values.map { |esito| esito.error.code }).to all(eq("R422-LEASE-001")), host_id.inspect
      end
      expect(Agents::Lease.count).to eq(0)
    end

    # La revoca vale subito, e vale su tutte e tre: una macchina a cui è stato tolto l'accesso non
    # deve poter nemmeno prolungare un lavoro già in mano.
    it "nessuna porta lascia agire una macchina revocata, nemmeno su un lucchetto che è suo" do
      create(:agent_lease, organization:, ticket:, host:, run_id: "run-42",
                           expires_at: 5.minutes.from_now)
      host.update!(revoked_at: Time.current)

      esiti = da_ogni_porta(params_validi)

      expect(esiti.values).to all(have_attributes(error: have_attributes(code: "R403-LEASE-001",
                                                                        status: :forbidden)))
      expect(Agents::Lease.where(ticket:).sole.run_id).to eq("run-42")
    end

    # Sul canale delle persone il titolare arriva dal token e non è falsificabile: un host_id nel
    # corpo sarebbe solo un modo per firmarsi con un altro nome.
    it "nessuna porta accetta un host_id dichiarato da una persona" do
      account = create(:membership, organization:).account
      params = { ticket: ticket.code, host_id: host.id, run_id: "run-cli", ttl_seconds: 60 }
      esiti = {
        prendere: Agents::Leases::Acquire.call(
          organization:, holder: Agents::Leases::Holder.account(account), ticket_reference: ticket.code,
          params: params.merge(agent: "triage")
        ),
        rinnovare: Agents::Leases::Renew.call(
          organization:, holder: Agents::Leases::Holder.account(account), ticket_reference: ticket.code, params:
        ),
        rilasciare: Agents::Leases::Release.call(
          organization:, holder: Agents::Leases::Holder.account(account), ticket_reference: ticket.code,
          params: params.except(:ttl_seconds)
        )
      }

      expect(esiti.values.map { |esito| esito.error.code }).to all(eq("R422-LEASE-001"))
      expect(Agents::Lease.count).to eq(0)
    end

    it "nessuna porta lascia agire una persona fuori dall'organizzazione" do
      estranea = create(:account)
      params = { ticket: ticket.code, run_id: "run-cli", ttl_seconds: 60 }
      esiti = {
        prendere: Agents::Leases::Acquire.call(
          organization:, holder: Agents::Leases::Holder.account(estranea), ticket_reference: ticket.code,
          params: params.merge(agent: "triage")
        ),
        rinnovare: Agents::Leases::Renew.call(
          organization:, holder: Agents::Leases::Holder.account(estranea), ticket_reference: ticket.code, params:
        ),
        rilasciare: Agents::Leases::Release.call(
          organization:, holder: Agents::Leases::Holder.account(estranea), ticket_reference: ticket.code,
          params: params.except(:ttl_seconds)
        )
      }

      expect(esiti.values).to all(have_attributes(error: have_attributes(code: "R403-LEASE-002",
                                                                        status: :forbidden)))
    end
  end

  describe "il nome della lavorazione" do
    it "nessuna porta accetta un nome vuoto o più lungo del consentito" do
      troppo_lungo = "x" * (described_class::MAX_IDENTIFIER_LENGTH + 1)

      [ nil, "", "   ", troppo_lungo ].each do |run_id|
        esiti = da_ogni_porta(params_validi.merge(run_id:))

        expect(esiti.values.map { |esito| esito.error.code }).to all(eq("R422-LEASE-001")), run_id.inspect
      end
      expect(Agents::Lease.count).to eq(0)
    end

    it "il limite è un confine, non un'approssimazione: la misura esatta passa" do
      al_limite = "x" * described_class::MAX_IDENTIFIER_LENGTH

      expect(da_ogni_porta(params_validi.merge(run_id: al_limite))[:prendere]).to be_ok
    end
  end

  describe "la durata richiesta" do
    # Rilasciare non chiede una durata; prendere e rinnovare sì, ed è lo stesso confine.
    it "prendere e rinnovare rifiutano una durata che non è un intero positivo" do
      [ 0, -1, 1.5, "60", nil, described_class::MAX_TTL_SECONDS + 1 ].each do |ttl_seconds|
        esiti = da_ogni_porta(params_validi.merge(ttl_seconds:))

        expect(esiti[:prendere].error.code).to eq("R422-LEASE-001"), ttl_seconds.inspect
        expect(esiti[:rinnovare].error.code).to eq("R422-LEASE-001"), ttl_seconds.inspect
      end
      expect(Agents::Lease.count).to eq(0)
    end

    it "rilasciare non chiede una durata e non si ferma se manca" do
      create(:agent_lease, organization:, ticket:, host:, run_id: "run-42",
                           expires_at: 5.minutes.from_now)

      esito = Agents::Leases::Release.call(
        organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: ticket.code,
        params: { ticket: ticket.code, host_id: host.id, run_id: "run-42" }
      )

      expect(esito).to be_ok
    end

    it "il tetto della durata è un confine: la misura esatta passa" do
      esito = da_ogni_porta(params_validi.merge(ttl_seconds: described_class::MAX_TTL_SECONDS))[:prendere]

      expect(esito).to be_ok
    end
  end

  describe "il riferimento del ticket" do
    it "nessuna porta accetta un riferimento malformato" do
      [ "../CYAU-1", "CYAU-0", "CYAU", "cyau-1x", "" ].each do |riferimento|
        esiti = {
          prendere: Agents::Leases::Acquire.call(
            organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: riferimento,
            params: params_validi.merge(ticket: riferimento)
          ),
          rinnovare: Agents::Leases::Renew.call(
            organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: riferimento,
            params: params_validi.except(:agent).merge(ticket: riferimento)
          ),
          rilasciare: Agents::Leases::Release.call(
            organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: riferimento,
            params: params_validi.except(:agent, :ttl_seconds).merge(ticket: riferimento)
          )
        }

        expect(esiti.values.map { |esito| esito.error.code }).to all(eq("R422-LEASE-001")), riferimento.inspect
      end
      expect(Agents::Lease.count).to eq(0)
    end

    # Il riferimento arriva due volte, nell'indirizzo e nel corpo: se non coincidono la richiesta non
    # dice quale ticket vuole, e nessuna porta indovina per lei.
    it "nessuna porta accetta indirizzo e corpo che indicano ticket diversi" do
      esiti = da_ogni_porta(params_validi.merge(ticket: "CYAU-999"))

      expect(esiti.values.map { |esito| esito.error.code }).to all(eq("R422-LEASE-001"))
    end

    it "nessuna porta risolve il ticket di un'altra organizzazione" do
      estraneo = create(:ticket)
      esiti = {
        prendere: Agents::Leases::Acquire.call(
          organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: estraneo.code,
          params: params_validi.merge(ticket: estraneo.code)
        ),
        rinnovare: Agents::Leases::Renew.call(
          organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: estraneo.code,
          params: params_validi.except(:agent).merge(ticket: estraneo.code)
        ),
        rilasciare: Agents::Leases::Release.call(
          organization:, holder: Agents::Leases::Holder.host(host), ticket_reference: estraneo.code,
          params: params_validi.except(:agent, :ttl_seconds).merge(ticket: estraneo.code)
        )
      }

      expect(esiti.values).to all(have_attributes(error: have_attributes(code: "R404-LEASE-001",
                                                                        status: :not_found)))
    end
  end

  describe "la fase dichiarata" do
    # La fase si valida prima di qualunque lock e di qualunque scrittura: una fase che non esiste
    # riceve sempre la stessa risposta, qualunque sia lo stato del lucchetto.
    it "nessuna porta accetta una fase che non esiste, con o senza lucchetto attivo" do
      senza_lucchetto = da_ogni_porta(params_validi.merge(execution_phase: "fase_che_non_esiste"))

      create(:agent_lease, organization:, ticket:, host:, run_id: "run-42",
                           expires_at: 5.minutes.from_now)
      con_lucchetto = da_ogni_porta(params_validi.merge(execution_phase: "fase_che_non_esiste"))

      expect(senza_lucchetto.values.map { |esito| esito.error.code }).to all(eq("R422-LEASE-001"))
      expect(con_lucchetto.values.map { |esito| esito.error.code }).to all(eq("R422-LEASE-001"))
      expect(Agents::Lease.where(ticket:).sole.run_id).to eq("run-42")
    end
  end

  describe "chi tiene il ticket, nella risposta di rifiuto" do
    # Il rifiuto porta il nome leggibile del titolare: chi lo riceve lo dice a una persona senza fare
    # una seconda domanda. E il titolare può essere una persona, non solo una macchina.
    it "porta il nome della persona che tiene il ticket" do
      persona = create(:membership, organization:).account
      create(:agent_lease, :held_by_account, organization:, ticket:, account: persona,
                           run_id: "run-cli", expires_at: 5.minutes.from_now)

      esito = da_ogni_porta(params_validi)[:rinnovare]

      expect(esito.error).to have_attributes(code: "R409-LEASE-001", status: :conflict)
      expect(esito.error.details.fetch(:holder)).to include(
        ticket: ticket.code, host_id: nil, account_id: persona.id, run_id: "run-cli"
      )
      expect(esito.error.details.dig(:holder, :held_by))
        .to include(kind: :account, id: persona.id, name: persona.name)
    end

    it "porta il nome della macchina che tiene il ticket" do
      create(:agent_lease, organization:, ticket:, host: altro_host, run_id: "run-altro",
                           expires_at: 5.minutes.from_now)

      esito = da_ogni_porta(params_validi)[:rinnovare]

      expect(esito.error.details.dig(:holder, :held_by))
        .to include(kind: :host, id: altro_host.id, name: altro_host.hostname)
    end
  end
end
