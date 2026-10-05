# frozen_string_literal: true

require "rails_helper"

# CYRA-279 — i ticket che un host ha lavorato, dal più recente. Una riga per LAVORAZIONE, non per
# tentativo: chi legge vuole sapere quali ticket ha toccato, non quante volte ci è tornato sopra.
RSpec.describe Agents::Hosts::WorkedTickets do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }

  def concluded(workflow:, phase: "triage", status: :approved, seconds: 60, age: 1.hour)
    started = age.ago
    create(:agent_attempt, organization:, host:, phase:, status:, workflow:,
                           started_at: started, finished_at: started + seconds)
  end

  it "riassume una lavorazione in una riga sola" do
    workflow = create(:agent_workflow, organization:)
    concluded(workflow:, phase: "triage", seconds: 100, age: 3.hours)
    concluded(workflow:, phase: "planner", status: :review_failed, seconds: 200, age: 2.hours)

    row = described_class.call(host:).records.sole

    expect(row.workflow_id).to eq(workflow.id)
    expect(row.attempts).to eq(2)
    expect(row.host_seconds).to eq(300)
    expect(row.phases).to eq(%w[triage planner])
    expect(row.last_status).to eq("review_failed")
    expect(row.ticket).to eq(workflow.ticket)
  end

  it "ordina le fasi come il flusso, non come sono capitate" do
    workflow = create(:agent_workflow, organization:)
    concluded(workflow:, phase: "autopilot", age: 1.hour)
    concluded(workflow:, phase: "triage", age: 3.hours)

    expect(described_class.call(host:).records.sole.phases).to eq(%w[triage autopilot])
  end

  it "mette in cima la lavorazione toccata più di recente" do
    old = create(:agent_workflow, organization:)
    recent = create(:agent_workflow, organization:)
    concluded(workflow: old, age: 5.days)
    concluded(workflow: recent, age: 1.hour)

    expect(described_class.call(host:, range: "all").records.map(&:workflow_id)).to eq([ recent.id, old.id ])
  end

  it "espone il tempo di lavorazione solo per i ticket arrivati in fondo" do
    done = create(:agent_workflow, organization:, triage_requested_at: 6.hours.ago, completed_at: 3.hours.ago)
    open_one = create(:agent_workflow, organization:, completed_at: nil)
    concluded(workflow: done, age: 5.hours)
    concluded(workflow: open_one, age: 4.hours)

    rows = described_class.call(host:).records.index_by(&:workflow_id)

    expect(rows[done.id].workflow_seconds).to be_within(1).of(3.hours.to_i)
    expect(rows[open_one.id].workflow_seconds).to be_nil
  end

  it "ignora gli attempt di altri host e quelli ancora aperti" do
    other = create(:agent_host, organization:)
    mine = create(:agent_workflow, organization:)
    concluded(workflow: mine)
    create(:agent_attempt, organization:, host: other, workflow: create(:agent_workflow, organization:),
                           status: :approved, started_at: 1.hour.ago, finished_at: 30.minutes.ago)
    create(:agent_attempt, organization:, host:, workflow: create(:agent_workflow, organization:),
                           status: :running, started_at: 5.minutes.ago)

    expect(described_class.call(host:).records.map(&:workflow_id)).to eq([ mine.id ])
  end

  it "rispetta il periodo scelto" do
    concluded(workflow: create(:agent_workflow, organization:), age: 2.days)
    concluded(workflow: create(:agent_workflow, organization:), age: 60.days)

    expect(described_class.call(host:, range: "7d").total).to eq(1)
    expect(described_class.call(host:, range: "all").total).to eq(2)
  end

  it "pagina contando le lavorazioni, non i tentativi" do
    3.times do
      workflow = create(:agent_workflow, organization:)
      concluded(workflow:, phase: "triage")
      concluded(workflow:, phase: "planner")
    end

    result = described_class.call(host:, page: 1, per: 2)

    expect(result.total).to eq(3)
    expect(result.total_pages).to eq(2)
    expect(result.records.size).to eq(2)
  end

  it "host senza storia: nessuna riga, nessun errore" do
    result = described_class.call(host:)

    expect(result.records).to be_empty
    expect(result.total).to eq(0)
  end

  # CYRA-924 — the list sorts on its columns (C9); an unknown key keeps the latest first.
  describe "sort" do
    let!(:short_one) { create(:agent_workflow, organization:) }
    let!(:long_one) { create(:agent_workflow, organization:) }

    before do
      concluded(workflow: short_one, seconds: 10, age: 1.hour)
      concluded(workflow: long_one, seconds: 900, age: 2.hours)
    end

    def ids(sort) = described_class.call(host:, sort:).records.map(&:workflow_id)

    it "sorts by host time both ways" do
      expect(ids("host_time")).to eq([ short_one.id, long_one.id ])
      expect(ids("-host_time")).to eq([ long_one.id, short_one.id ])
    end

    it "sorts by ticket code" do
      expected = [ short_one, long_one ].sort_by { |w| w.ticket.number }.map(&:id)
      expect(ids("ticket")).to eq(expected)
    end

    it "ignores an unknown key" do
      expect(ids("evil; DROP")).to eq([ short_one.id, long_one.id ])
    end
  end
end
