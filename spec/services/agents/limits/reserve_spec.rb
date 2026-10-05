# frozen_string_literal: true

require "rails_helper"

# Questi comportamenti erano provati attraverso POST /api/v1/limits/reservations, endpoint rimosso coi
# typed agent (CYAU-85): risolveva lo scope dall'agente e dal suo target, autorità che non esiste più.
# Il gate però è vivo e più importante di prima — è ciò che impedisce a una flotta di host di partire
# senza freno — e adesso ha un solo chiamante, Agents::TicketQueues::Claim. Le prove tornano qui, sul
# service, invece di sparire con l'endpoint che le ospitava.
RSpec.describe Agents::Limits::Reserve do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "LIM") }
  let(:registration) do
    Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner-1", platform: "linux", arch: "arm64"
    ).value
  end
  let(:host) { registration.fetch(:host) }

  # Register crea il service account cieco: senza un legame esplicito col progetto la ProjectScope
  # host-only è vuota e ogni prenotazione è fuori scope.
  before do
    allow(Agents::Limits::Clock).to receive(:current) { Time.current }
    create(:project_membership, account: host.service_account, project:)
  end

  def reserve(phase: "triage", key: SecureRandom.uuid, **overrides)
    described_class.call(organization:, host:, project:, phase:, idempotency_key: key, **overrides)
  end

  describe "confini di autorità" do
    it "rifiuta una fase che non esiste" do
      result = reserve(phase: "inventata")

      expect(result).to be_err
      expect(Agents::LimitReservation.count).to be_zero
    end

    it "rifiuta un host revocato" do
      host.update!(revoked_at: Time.current)

      expect(reserve).to be_err
    end

    it "rifiuta un host che non vede il progetto" do
      other = create(:project, organization:, key: "OTH")

      expect(described_class.call(
        organization:, host:, project: other, phase: "triage", idempotency_key: SecureRandom.uuid
      )).to be_err
    end

    it "rifiuta un host di un'altra organizzazione" do
      foreign = Agents::Hosts::Register.call(
        organization: create(:organization), fingerprint: SecureRandom.hex(12),
        hostname: "estraneo", platform: "linux", arch: "arm64"
      ).value.fetch(:host)

      expect(described_class.call(
        organization:, host: foreign, project:, phase: "triage", idempotency_key: SecureRandom.uuid
      )).to be_err
    end

    it "rifiuta un costo che non è rappresentabile" do
      expect(reserve(estimated_cost: "0.00001")).to be_err
    end
  end

  describe "idempotenza" do
    it "ripete la stessa decisione senza contarla due volte" do
      key = SecureRandom.uuid
      create(:agent_limit_policy, organization:, max_daily_runs: 3)

      first = reserve(key:)
      second = reserve(key:)

      expect(first.value.replayed).to be(false)
      expect(second.value.replayed).to be(true)
      expect(second.value.reservation.id).to eq(first.value.reservation.id)
      expect(Agents::LimitReservation.count).to eq(1)
      expect(Agents::LimitUsage.sole.runs).to eq(1)
    end

    it "tratta due fasi diverse sotto la stessa chiave come richieste diverse, non come un replay" do
      key = SecureRandom.uuid
      reserve(phase: "triage", key:)

      expect(reserve(phase: "planner", key:)).to be_err
    end
  end

  describe "motivi di diniego" do
    it "nega tutto quando il kill switch è alzato" do
      create(:agent_limit_policy, organization:, stop_dispatch: true)

      expect(reserve.value.reservation).to have_attributes(outcome: "denied", denial_reason: "kill_switch")
    end

    it "nega quando la fase dura più del tetto di runtime consentito" do
      create(:agent_limit_policy, organization:, max_runtime_seconds: 60)

      expect(reserve.value.reservation).to have_attributes(outcome: "denied", denial_reason: "max_runtime")
    end

    it "nega quando le partenze in parallelo sono esaurite" do
      create(:agent_limit_policy, organization:, max_parallel: 1)

      expect(reserve.value.reservation.outcome).to eq("granted")
      expect(reserve.value.reservation).to have_attributes(outcome: "denied", denial_reason: "max_parallel")
    end

    it "applica il budget giornaliero di partenze senza sovraconsumo" do
      create(:agent_limit_policy, organization:, max_daily_runs: 2)

      outcomes = 3.times.map { reserve.value.reservation.denial_reason || "granted" }

      expect(outcomes).to eq(%w[granted granted max_daily_runs])
      expect(Agents::LimitUsage.sole.runs).to eq(2)
    end

    it "nega esplicitamente quando serve un costo e non è noto" do
      create(:agent_limit_policy, organization:, max_daily_cost: 10)

      reservation = reserve.value.reservation

      expect(reservation).to have_attributes(outcome: "denied", denial_reason: "estimated_cost_unavailable")
      expect(reservation.estimated_cost).to be_nil
      expect(Agents::LimitUsage.sole).to have_attributes(runs: 0, cost: 0)
    end

    it "nega quando il costo previsto sfonda il budget giornaliero" do
      create(:agent_limit_policy, organization:, max_daily_cost: 10)

      expect(reserve(estimated_cost: 9).value.reservation.outcome).to eq("granted")
      expect(reserve(estimated_cost: 9).value.reservation)
        .to have_attributes(outcome: "denied", denial_reason: "max_daily_cost")
      expect(Agents::LimitUsage.sole.cost).to eq(9)
    end
  end

  describe "concessione" do
    it "concede, dà una scadenza dal profilo della fase e conta la partenza" do
      reservation = reserve(estimated_cost: "0.5000").value.reservation

      expect(reservation).to have_attributes(outcome: "granted", denial_reason: nil, phase: "triage")
      expect(reservation.expires_at).to be_within(5.seconds).of(
        Time.current + Agents::PhaseProfile.for("triage").ttl.seconds
      )
      expect(Agents::LimitUsage.sole).to have_attributes(runs: 1, cost: BigDecimal("0.5"))
    end

    it "crea da sé la policy di default dell'organizzazione alla prima prenotazione" do
      expect { reserve }.to change {
        Agents::LimitPolicy.where(organization:, project: nil, runtime: nil).count
      }.from(0).to(1)
    end
  end
end
