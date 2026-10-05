# frozen_string_literal: true

require "rails_helper"

# CYRA-183: il percorso di una lavorazione nella pagina host. Lo stato di ogni passaggio è DERIVATO dai
# timestamp del workflow (nessuna colonna nuova che possa divergere) e la fase in corso arriva dal lease,
# non da un'inferenza: è ciò che l'host detiene davvero in questo istante.
RSpec.describe Agents::RunTimeline do
  let(:organization) { create(:organization) }
  let(:workflow) { create(:agent_workflow, organization:) }

  def statuses(timeline) = timeline.steps.to_h { |s| [ s.phase, s.status ] }

  it "espone i passaggi nell'ordine canonico di PhaseProfile, non in uno riscritto" do
    timeline = described_class.new(workflow:)
    expect(timeline.steps.map(&:phase)).to eq(Agents::PhaseProfile.phases)
  end

  it "un workflow appena richiesto ha tutti i passaggi da fare" do
    expect(statuses(described_class.new(workflow:)).values).to all(eq(:pending))
  end

  it "marca concluso il passaggio che ha il suo timestamp di completamento" do
    workflow.update!(triaged_at: Time.current)
    expect(statuses(described_class.new(workflow:))["triage"]).to eq(:done)
    expect(statuses(described_class.new(workflow:))["autopilot"]).to eq(:pending)
  end

  # Senza lease (run ferma, lease scaduto) la fase in corso va DEDOTTA: `ready_execution_phase` non serve,
  # dice quale fase è reclamabile e una già avviata non lo è più.
  describe "fase dedotta quando manca il lease" do
    it "una fase avviata e non conclusa risulta in corso" do
      workflow.update!(triage_requested_at: 2.hours.ago, triage_started_at: 1.hour.ago, triaged_at: nil)
      expect(statuses(described_class.new(workflow:))["triage"]).to eq(:current)
    end

    it "col triage chiuso e nessun piano, il passaggio in corso è il planner" do
      workflow.update!(triaged_at: 1.hour.ago, planned_at: nil)
      expect(statuses(described_class.new(workflow:))["planner"]).to eq(:current)
    end

    it "un workflow del tutto concluso non ha passaggi in corso" do
      workflow.update!(triaged_at: 3.hours.ago, planned_at: 2.hours.ago, approved_at: 2.hours.ago,
                       autopilot_started_at: 1.hour.ago, autopilot_completed_at: 30.minutes.ago,
                       autopilot_approved_at: 20.minutes.ago, closer_staging_started_at: 15.minutes.ago,
                       closer_staging_completed_at: 10.minutes.ago, closer_production_started_at: 5.minutes.ago,
                       completed_at: Time.current)
      expect(statuses(described_class.new(workflow:)).values).not_to include(:current)
    end
  end

  it "la fase del lease vince: è quella in corso anche se i timestamp direbbero altro" do
    workflow.update!(triaged_at: Time.current)
    timeline = described_class.new(workflow:, current_phase: "planner")

    expect(statuses(timeline)).to include("triage" => :done, "planner" => :current)
  end

  # Un retry rilegge la stessa fase: l'host la sta rieseguendo ORA, e la pagina deve dirlo.
  it "una fase già conclusa ma ripresa dal lease risulta in corso, non conclusa" do
    workflow.update!(triaged_at: Time.current)
    expect(statuses(described_class.new(workflow:, current_phase: "triage"))["triage"]).to eq(:current)
  end

  it "closer_production si chiude col completamento del workflow" do
    workflow.update!(completed_at: Time.current)
    expect(statuses(described_class.new(workflow:))["closer_production"]).to eq(:done)
  end

  describe "prodotti" do
    it "senza workflow non inventa nulla" do
      products = described_class.new(workflow: nil).products
      expect(products.plan_version).to be_nil
      expect(products.attempts_count).to eq(0)
      expect(products.branch_name).to be_nil
    end

    it "riporta l'ULTIMA versione di piano e il numero di tentativi" do
      attempt = create(:agent_attempt, workflow:, organization:)
      2.times do |i|
        Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano #{i}", scenarios: [ "Uno" ],
                             definition_of_done: [], notes: [], ticket_snapshot_digest: "snapshot")
      end

      products = described_class.new(workflow: workflow.reload).products
      expect(products.plan_version).to eq(2)
      expect(products.attempts_count).to eq(1)
    end

    it "riporta ramo e proposta di modifica del ticket quando esistono" do
      repository = create(:github_repository, project: workflow.ticket.project)
      create(:github_branch, repository:, ticket: workflow.ticket, name: "ticket/#{workflow.ticket.code}")
      create(:github_pull_request, repository:, ticket: workflow.ticket, number: 41)

      products = described_class.new(workflow: workflow.reload).products
      expect(products.branch_name).to eq("ticket/#{workflow.ticket.code}")
      expect(products.pull_request_number).to eq(41)
    end
  end
end
