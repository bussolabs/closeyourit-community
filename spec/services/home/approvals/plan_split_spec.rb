# frozen_string_literal: true

require "rails_helper"

# CYRA-1152 — in the approvals queue an epic's split says what it is: the row names how many tickets it
# creates, and the card lists the children and what each waits for.
RSpec.describe "approvals and an epic's split", type: :service do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account:, organization:, role: :owner) }
  let(:project) { create(:project, organization:) }
  let(:visible_projects) { Projects::Project.where(id: project.id) }
  let(:visible_tickets) { Ticketing::Ticket.where(project_id: visible_projects.select(:id)) }

  before { organization.update_column(:cto_id, account.id) }

  def child(id, dependencies = [])
    { "id" => id, "title" => "Child #{id}", "description" => "Work of #{id}.", "dependencies" => dependencies,
      "scenarios" => [ { "id" => "SC-1", "title" => "Works", "given" => "a", "when" => "b", "then" => "c", "expected" => "d" } ] }
  end

  def planned(ticket, content)
    workflow = create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triaged_at: 1.day.ago, planned_at: Time.current)
    Agents::Plan.create!(workflow:, attempt: create(:agent_attempt, organization:, workflow:), contract_version: 2,
                         technical_analysis: "Plan", scenarios: [], definition_of_done: [ "RSpec" ], notes: [],
                         ticket_snapshot_digest: "snapshot", content:)
    workflow
  end

  let!(:split_workflow) do
    planned(create(:ticket, :epic, organization:, project:),
            { "summary" => "Split", "children" => [ child("CH-1"), child("CH-2"), child("CH-3", %w[CH-1 CH-2]) ] })
  end
  let!(:plain_workflow) { planned(create(:ticket, organization:, project:), { "summary" => "Plain plan" }) }

  def queue_item(workflow)
    Home::Approvals::Queue.call(account:, organization:, visible_projects:, visible_tickets:)
                          .items.find { |item| item.key == "agent_plan:#{workflow.id}" }
  end

  def card(workflow)
    Home::Approvals::Detail.call(account:, organization:, visible_projects:, visible_tickets:,
                                 key: "agent_plan:#{workflow.id}")
  end

  it "tells on the queue row that the plan splits the epic, and into how many tickets" do
    expect(queue_item(split_workflow).plan_split).to eq(3)
    expect(queue_item(plain_workflow).plan_split).to be_nil
  end

  it "counts the children of the latest plan only" do
    Agents::Plan.create!(workflow: split_workflow, attempt: create(:agent_attempt, organization:, workflow: split_workflow),
                         contract_version: 2, technical_analysis: "Rewritten", scenarios: [], definition_of_done: [ "RSpec" ],
                         notes: [], ticket_snapshot_digest: "snapshot", content: { "summary" => "No split anymore" })

    expect(queue_item(split_workflow).plan_split).to be_nil
  end

  it "lists the proposed children on the card, each after what it waits for" do
    split = card(split_workflow).split

    expect(split.ordered.map(&:id)).to eq(%w[CH-1 CH-2 CH-3])
    expect(split.ordered.last.dependencies).to eq(%w[CH-1 CH-2])
    expect(card(plain_workflow).split).to be_nil
  end

  it "renders the children and what each waits for" do
    split = card(split_workflow).split
    html = I18n.with_locale(:it) do
      ApplicationController.render(partial: "member/home/approvals/plan_split", locals: { split: })
    end
    page = Nokogiri::HTML(html)

    expect(page.css("[data-test=approvals-plan-split-child]").size).to eq(3)
    expect(page.css("[data-test=approvals-plan-split-waits]").map { |node| node.text.strip })
      .to eq([ "Può partire subito", "Può partire subito", "Aspetta: CH-1, CH-2" ])
  end
end
