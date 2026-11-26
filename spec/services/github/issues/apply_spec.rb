# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — when the same field changes on both sides, the newer change wins and the history
# records both.
RSpec.describe Github::Issues::Apply do
  let(:link) { create(:github_issue, github_updated_at: 2.hours.ago) }
  let(:ticket) { link.ticket }

  def issue(overrides = {})
    { "number" => link.number, "title" => ticket.title, "body" => ticket.description.to_s, "state" => "open",
      "labels" => [], "assignees" => [], "html_url" => link.html_url, "user" => { "login" => "alice" } }.merge(overrides)
  end

  # A person renames the ticket on CloseYourIt, an hour ago.
  def rename_here
    Github::Issues::TicketFields.update(ticket, { title: "Titolo da CloseYourIt" }, actor: ticket.reporter)
    ticket.update_column(:updated_at, 1.hour.ago)
  end

  it "the newer GitHub title wins over an older one written here, and both stay in the history" do
    rename_here

    described_class.call(link:, issue: issue("title" => "Titolo da GitHub", "updated_at" => Time.current.iso8601))

    expect(ticket.reload.title).to eq("Titolo da GitHub")
    expect(ticket.events.where(action: "updated").count).to eq(2)
  end

  it "an older GitHub title loses to a newer one written here: recorded, and the ticket's value is sent back" do
    rename_here
    ticket.update_column(:updated_at, Time.current)

    expect do
      described_class.call(link:, issue: issue("title" => "Titolo da GitHub", "updated_at" => 90.minutes.ago.iso8601))
    end.to have_enqueued_job(Github::Issues::PushJob).with(ticket_id: ticket.id)

    expect(ticket.reload.title).to eq("Titolo da CloseYourIt")
    expect(ticket.events.find_by(action: "github_change_superseded").data["fields"]).to eq(%w[title])
  end

  it "a delivery identical to the state already seen changes nothing" do
    expect { described_class.call(link:, issue: issue("updated_at" => Time.current.iso8601)) }
      .not_to change { ticket.events.count }
  end

  it "a text longer than the ticket holds enters cut and is marked, so it never goes back" do
    long = "a" * (Ticketing::Constants::DESCRIPTION_MAX_CHARS + 500)

    described_class.call(link:, issue: issue("body" => long, "updated_at" => Time.current.iso8601))

    expect(ticket.reload.description.length).to be <= Ticketing::Constants::DESCRIPTION_MAX_CHARS
    expect(ticket.description).to include(link.html_url)
    expect(link.reload).to be_truncated("description")
  end

  it "a text that fits again is no longer marked as cut" do
    link.update!(truncated_fields: %w[description])

    described_class.call(link:, issue: issue("body" => "Testo breve", "updated_at" => Time.current.iso8601))

    expect(link.reload).not_to be_truncated("description")
  end

  context "with labels mapped to a type and a priority" do
    let(:organization) { ticket.project.organization }
    let(:urgent) { create(:ticket_priority, organization:) }

    before { link.repository.update!(label_kinds: { "task" => "task" }, label_priorities: { "urgent" => urgent.id }) }

    it "the labels set the ticket's type and priority" do
      described_class.call(link:, issue: issue("labels" => [ { "name" => "Task" }, { "name" => "urgent" } ],
                                               "updated_at" => Time.current.iso8601))

      expect(ticket.reload).to have_attributes(kind: "task", priority_id: urgent.id)
    end

    it "a label mapped to nothing leaves type and priority as they are" do
      expect do
        described_class.call(link:, issue: issue("labels" => [ { "name" => "wontfix" } ], "updated_at" => Time.current.iso8601))
      end.not_to change { ticket.reload.attributes.slice("kind", "priority_id") }
    end
  end

  context "with assignees" do
    it "assigns the member who wrote that GitHub name" do
      member = create(:account, github_login: "alice-gh")
      create(:membership, account: member, organization: ticket.project.organization)

      described_class.call(link:, issue: issue("assignees" => [ { "login" => "alice-gh" } ], "updated_at" => Time.current.iso8601))

      expect(ticket.reload.assignee).to eq(member)
      expect(ticket.events.where(action: "github_assignee_unknown")).not_to exist
    end

    it "a GitHub name nobody wrote leaves the ticket unassigned, and says who it was" do
      described_class.call(link:, issue: issue("assignees" => [ { "login" => "ghost" } ], "updated_at" => Time.current.iso8601))

      expect(ticket.reload.assignee).to be_nil
      expect(ticket.events.find_by(action: "github_assignee_unknown").data["login"]).to eq("ghost")
    end

    it "no assignee on GitHub leaves the ticket unassigned" do
      link.update!(synced_state: link.synced_state.deep_merge("remote" => { "assignees" => %w[bob] }))

      described_class.call(link:, issue: issue("updated_at" => Time.current.iso8601))

      expect(ticket.reload.assignee).to be_nil
      expect(link.reload.remote_state["assignees"]).to eq([])
    end
  end

  it "a change the ticket refuses stays written in its history" do
    create(:agent_workflow, ticket:, triage_started_at: Time.current)
    original_title = ticket.title

    described_class.call(link:, issue: issue("title" => "Titolo rifiutato", "updated_at" => Time.current.iso8601))

    expect(ticket.reload.title).to eq(original_title)
    expect(ticket.events.find_by(action: "github_change_declined").data).to include("fields" => %w[title], "reason" => "R409-TICKET-006")
  end

  it "a closed issue with no done status to move to stays written in the history" do
    organization = ticket.project.organization
    organization.ticket_statuses.where(category: :done).update_all(active: false)
    original_status = ticket.status

    described_class.call(link:, issue: issue("state" => "closed", "updated_at" => Time.current.iso8601))

    expect(ticket.events.find_by(action: "github_change_declined").data["fields"]).to eq(%w[status])
    expect(ticket.reload.status).to eq(original_status)
  end

  it "ignores an older GitHub delivery without blaming a local edit" do
    original_title = ticket.title
    original_state = link.synced_state

    expect do
      described_class.call(link:, issue: issue("title" => "Old remote title", "updated_at" => 3.hours.ago.iso8601))
    end.not_to change { ticket.events.count }

    expect(ticket.reload.title).to eq(original_title)
    expect(link.reload.synced_state).to eq(original_state)
  end

  it "a closed issue whose ticket is already done changes nothing, even without the GitHub account" do
    ticket.update!(status: create(:ticket_status, :done, organization: ticket.project.organization))
    link.update!(synced_state: { "remote" => link.remote_state, "local" => Github::Issues::Snapshot.local(ticket) })
    allow(Github::Issues::SystemAccount).to receive(:call).and_return(Result.err(AppError.new("no", code: "R422-TEST-001")))

    described_class.call(link:, issue: issue("state" => "closed", "updated_at" => Time.current.iso8601))

    expect(link.reload.remote_state["closed"]).to be(true)
    expect(ticket.events.where(action: "github_change_declined")).not_to exist
  end

  it "a link that never saw the ticket takes its state as it is now" do
    link.update!(synced_state: { "remote" => link.remote_state })

    described_class.call(link:, issue: issue("title" => "Nuovo", "updated_at" => Time.current.iso8601))

    expect(link.reload.local_state["title"]).to eq("Nuovo")
  end
end
