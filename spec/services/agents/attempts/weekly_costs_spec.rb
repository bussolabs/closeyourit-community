# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Attempts::WeeklyCosts do
  let(:organization) { create(:organization) }
  let(:alpha) { create(:project, organization:, key: "ALFA") }
  let(:beta) { create(:project, organization:, key: "BETA") }
  let(:alpha_workflow) { create(:agent_workflow, ticket: create(:ticket, organization:, project: alpha)) }
  let(:beta_workflow) { create(:agent_workflow, ticket: create(:ticket, organization:, project: beta)) }
  let(:week) { Date.new(2026, 9, 21) }

  def attempt(workflow:, phase:, cost:, finished_at:, model: "claude-opus-5-5")
    create(:agent_attempt, workflow:, phase:, status: :approved, cost_usd: cost, model:,
                           started_at: finished_at - 1.minute, finished_at:)
  end

  before do
    monday = Time.utc(2026, 9, 21, 0, 0, 1)
    attempt(workflow: alpha_workflow, phase: "triage", cost: "0.50", finished_at: monday)
    attempt(workflow: alpha_workflow, phase: "autopilot", cost: "3.25", finished_at: monday + 2.days)
    attempt(workflow: beta_workflow, phase: "triage", cost: "0.75", finished_at: Time.utc(2026, 9, 27, 23, 59))
    attempt(workflow: beta_workflow, phase: "autopilot", cost: nil, finished_at: monday + 1.day,
            model: "gpt-6-astra")
    attempt(workflow: alpha_workflow, phase: "triage", cost: "9.00", finished_at: Time.utc(2026, 9, 28, 0, 0, 1))
    attempt(workflow: alpha_workflow, phase: "triage", cost: "9.00", finished_at: Time.utc(2026, 9, 20, 23, 59))
  end

  it "somma i costi della settimana UTC per fase, con i tentativi senza costo contati a parte" do
    report = described_class.call(organization:, week:)

    expect(report.range).to eq(Time.utc(2026, 9, 21)...Time.utc(2026, 9, 28))
    expect(report.by_phase.map(&:to_h)).to eq([
      { label: "autopilot", attempts: 2, priced: 1, cost: BigDecimal("3.25") },
      { label: "triage", attempts: 2, priced: 2, cost: BigDecimal("1.25") }
    ])
    expect(report.total.to_h).to eq(label: "totale", attempts: 4, priced: 3, cost: BigDecimal("4.5"))
  end

  it "resta nell'organizzazione chiesta" do
    other = create(:agent_workflow, organization: create(:organization))
    attempt(workflow: other, phase: "triage", cost: "7.00", finished_at: Time.utc(2026, 9, 22))

    expect(described_class.call(organization:, week:).total.cost).to eq(BigDecimal("4.5"))
  end

  it "somma i costi per progetto" do
    expect(described_class.call(organization:, week:).by_project.map(&:to_h)).to eq([
      { label: "ALFA", attempts: 2, priced: 2, cost: BigDecimal("3.75") },
      { label: "BETA", attempts: 2, priced: 1, cost: BigDecimal("0.75") }
    ])
  end

  it "porta la settimana al suo lunedì, qualunque giorno si passi" do
    expect(described_class.call(organization:, week: Date.new(2026, 9, 24)).range.begin).to eq(Time.utc(2026, 9, 21))
  end

  it "scrive righe leggibili, coi totali in dollari" do
    lines = described_class.call(organization:, week:).lines

    expect(lines.first).to eq("Costi dell'automazione dal 2026-09-21 al 2026-09-27 (UTC)")
    expect(lines).to include("  autopilot            2 tentativi, 1 con costo     $3.25")
    expect(lines).to include("  ALFA                 2 tentativi, 2 con costo     $3.75")
    expect(lines.last).to eq("Totale               4 tentativi, 3 con costo     $4.50")
  end

  it "dice che la settimana è vuota invece di stampare zeri" do
    expect(described_class.call(organization:, week: Date.new(2026, 1, 5)).lines)
      .to eq([ "Costi dell'automazione dal 2026-01-05 al 2026-01-11 (UTC)", "Nessun tentativo concluso." ])
  end
end
