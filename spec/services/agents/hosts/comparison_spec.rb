# frozen_string_literal: true

require "rails_helper"

# CYRA-451 — le stesse misure del rendimento, per più host insieme. Il punto è che i numeri di un
# host non sconfinino in quelli di un altro, e che il costo dichiari cosa non traccia.
RSpec.describe Agents::Hosts::Comparison, type: :service do
  let(:organization) { create(:organization) }
  let(:uno) { create(:agent_host, organization:, hostname: "mac-uno") }
  let(:due) { create(:agent_host, organization:, hostname: "mac-due") }

  def concluded(host:, phase: "triage", status: :approved, seconds: 60, age: 1.hour)
    workflow = create(:agent_workflow, organization:)
    started = age.ago
    create(:agent_attempt, organization:, host:, workflow:, phase:, status:,
                           started_at: started, finished_at: started + seconds)
    workflow
  end

  it "tiene separati i numeri di due host" do
    concluded(host: uno, status: :approved)
    concluded(host: uno, status: :rejected)
    concluded(host: due, status: :approved)

    rows = described_class.call(hosts: [ uno, due ])

    expect(rows[uno.id].attempts_count).to eq(2)
    expect(rows[uno.id].rejected_pct).to eq(50.0)
    expect(rows[due.id].attempts_count).to eq(1)
    expect(rows[due.id].rejected_pct).to eq(0.0)
  end

  it "un host senza storia nel periodo non è zero per cento, è non misurato" do
    concluded(host: uno)

    rows = described_class.call(hosts: [ uno, due ])

    expect(rows[due.id].any?).to be(false)
    expect(rows[due.id].rejected_pct).to be_nil
  end

  it "somma il costo stimato per host e dichiara le partenze senza costo" do
    create(:agent_limit_reservation, organization:, host: uno, estimated_cost: "1.2500")
    create(:agent_limit_reservation, organization:, host: uno, estimated_cost: nil)
    create(:agent_limit_reservation, organization:, host: due, estimated_cost: "0.5000")

    rows = described_class.call(hosts: [ uno, due ])

    expect(rows[uno.id].cost.total).to eq(BigDecimal("1.25"))
    expect(rows[uno.id].cost.partial?).to be(true)
    expect(rows[uno.id].cost.untracked).to eq(1)
    expect(rows[due.id].cost.partial?).to be(false)
  end

  it "il periodo restringe il perimetro" do
    concluded(host: uno, age: 2.days)
    concluded(host: uno, age: 60.days)

    expect(described_class.call(hosts: [ uno ], range: "7d")[uno.id].attempts_count).to eq(1)
    expect(described_class.call(hosts: [ uno ], range: "all")[uno.id].attempts_count).to eq(2)
  end

  it "senza host non interroga niente" do
    expect(described_class.call(hosts: [])).to eq({})
  end

  it "la mediana del tempo per ticket somma i passaggi della stessa lavorazione" do
    workflow = create(:agent_workflow, organization:)
    started = 1.hour.ago
    create(:agent_attempt, organization:, host: uno, workflow:, phase: "triage", status: :approved,
                           started_at: started, finished_at: started + 100)
    create(:agent_attempt, organization:, host: uno, workflow:, phase: "planner", status: :approved,
                           started_at: started, finished_at: started + 200)

    rows = described_class.call(hosts: [ uno ])

    expect(rows[uno.id].tickets_count).to eq(1)
    expect(rows[uno.id].host_seconds_median).to eq(300)
  end
end
