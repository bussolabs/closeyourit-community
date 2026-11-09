# frozen_string_literal: true

require "rails_helper"

# CYRA-1152 — the child tickets an epic's plan proposes, and when that proposal cannot stand.
RSpec.describe Agents::PlanSplit do
  def child(id, dependencies = [])
    { "id" => id, "title" => "Child #{id}", "description" => "Work of #{id}.", "dependencies" => dependencies,
      "scenarios" => [ { "id" => "SC-1", "title" => "Works", "given" => "a", "when" => "b", "then" => "c", "expected" => "d" } ] }
  end

  def split(*children) = described_class.new({ "children" => children })

  let(:epic) { build(:ticket, :epic) }
  let(:story) { build(:ticket, :story) }

  it "is empty on a plan without children" do
    expect(described_class.new({ "summary" => "Plan" })).not_to be_any
    expect(described_class.new(nil).problem(story)).to be_nil
  end

  it "orders every child after its prerequisites" do
    proposal = split(child("CH-3", %w[CH-1 CH-2]), child("CH-1"), child("CH-2"))

    expect(proposal.problem(epic)).to be_nil
    expect(proposal.ordered.map(&:id)).to eq(%w[CH-1 CH-2 CH-3])
  end

  it "stands only on an epic" do
    expect(split(child("CH-1"), child("CH-2")).problem(story)).to eq(:not_epic)
  end

  it "refuses children that wait for each other, or for themselves" do
    expect(split(child("CH-1", %w[CH-2]), child("CH-2", %w[CH-1])).problem(epic)).to eq(:cycle)
    expect(split(child("CH-1", %w[CH-1]), child("CH-2")).problem(epic)).to eq(:cycle)
  end

  it "refuses a prerequisite that names no proposed child" do
    expect(split(child("CH-1", %w[CH-7]), child("CH-2")).problem(epic)).to eq(:unknown_dependency)
  end

  it "refuses two children with the same id" do
    expect(split(child("CH-1"), child("CH-1")).problem(epic)).to eq(:duplicate_child)
  end

  it "refuses more children than the cap" do
    children = (1..(described_class::MAX_CHILDREN + 1)).map { |index| child("CH-#{index}") }

    expect(split(*children).problem(epic)).to eq(:too_many)
  end

  it "refuses a description or a title longer than the ticket takes, and accepts one right at the limit" do
    limit = Ticketing::Constants::DESCRIPTION_MAX_CHARS
    at_limit = child("CH-1").merge("description" => "a" * limit, "title" => "t" * described_class::TITLE_MAX_CHARS)

    expect(split(at_limit, child("CH-2")).problem(epic)).to be_nil
    expect(split(child("CH-1").merge("description" => "a" * (limit + 1)), child("CH-2")).problem(epic)).to eq(:too_long)
    expect(split(child("CH-1").merge("title" => "t" * 256), child("CH-2")).problem(epic)).to eq(:too_long)
  end

  it "keeps the caps in the shape the server checks at delivery" do
    child = described_class::CONTRACT.dig("items", "properties")

    expect(described_class::CONTRACT["maxItems"]).to eq(described_class::MAX_CHILDREN)
    expect(child.dig("title", "maxLength")).to eq(described_class::TITLE_MAX_CHARS)
    expect(child.dig("description", "maxLength")).to eq(Ticketing::Constants::DESCRIPTION_MAX_CHARS)
  end

  describe "on the plan" do
    let(:ticket) { create(:ticket, :epic, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }
    let(:attempt) { create(:agent_attempt, workflow:) }

    def plan_with(children)
      Agents::Plan.new(workflow:, attempt:, contract_version: 2, technical_analysis: "Plan", scenarios: [],
                       definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot",
                       content: { "summary" => "Split", "children" => children })
    end

    it "accepts an epic's proposal and keeps it with the plan" do
      plan = plan_with([ child("CH-1"), child("CH-2", %w[CH-1]) ])

      expect(plan.save).to be(true)
      expect(plan.reload).to be_split
      expect(plan.split.ordered.map(&:id)).to eq(%w[CH-1 CH-2])
    end

    it "refuses a proposal whose prerequisites go round" do
      expect(plan_with([ child("CH-1", %w[CH-2]), child("CH-2", %w[CH-1]) ])).not_to be_valid
    end

    it "refuses a proposal whose child description the ticket could not hold whole" do
      long = child("CH-1").merge("description" => "a" * (Ticketing::Constants::DESCRIPTION_MAX_CHARS + 1))

      expect(plan_with([ long, child("CH-2") ])).not_to be_valid
    end

    it "refuses a proposal on a ticket that is not an epic" do
      ticket.update!(kind: :story)

      expect(plan_with([ child("CH-1"), child("CH-2") ])).not_to be_valid
    end
  end
end
