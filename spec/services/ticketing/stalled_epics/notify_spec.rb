# frozen_string_literal: true

require "rails_helper"

# CYRA-1155 — the stalled-epic notice goes to whoever has to act, once per situation.
RSpec.describe Ticketing::StalledEpics::Notify do
  let(:organization) { create(:organization) }
  let(:cto) { member(role: :owner) }
  let(:project) { create(:project, organization:, key: "EPIC").tap { |record| record.update!(cto:) } }
  let(:epic) { create(:ticket, :epic, organization:, project:) }

  def member(role: :member)
    create(:account, locale: "it").tap { |account| create(:membership, account:, organization:, role:) }
  end

  def child = create(:ticket, organization:, project:, parent: epic)

  def awaiting_approval(ticket)
    create(:agent_workflow, ticket:, triage_requested_at: 3.hours.ago, triage_started_at: 3.hours.ago,
                            triaged_at: 2.hours.ago, planned_at: 1.hour.ago)
  end

  def notify
    stall = Ticketing::StalledEpics::Detect.call(organization:).value.sole
    described_class.call(stall:)
  end

  def notices(account, via: :in_app)
    Alerting::Notification.where(account:, event_type: :ticket_epic_stalled, via:)
  end

  it "tells the technical lead the epic is stalled and which question unblocks it" do
    ticket = child
    question = create(:ticket_question, :blocking, :from_agent, organization:, ticket:, body: "Quale ambiente?")

    notify

    notice = notices(cto).sole
    expect(notice.subject).to eq(epic)
    expect(notice.url).to eq(Rails.application.routes.url_helpers.member_ticket_path(epic))
    expect(notice.title).to include(epic.code)
    expect(notice.body).to include(ticket.code, question.body, cto.name)
  end

  it "sends nothing new while the situation stays the same" do
    create(:ticket_question, :blocking, :from_agent, organization:, ticket: child)

    notify
    expect { notify }.not_to(change { notices(cto).count })
  end

  it "sends a new notice naming the approval when a wait changes" do
    create(:ticket_question, :blocking, :from_agent, organization:, ticket: child)
    other = child
    create(:ticket_question, :blocking, :from_agent, organization:, ticket: other)
    notify

    awaiting_approval(other)

    expect { notify }.to change { notices(cto).count }.by(1)
    expect(notices(cto).order(:created_at).last.body).to include(I18n.t("ticketing.notifications.content.stalled_epic_waits.awaiting_approval", locale: :it))
  end

  it "reaches the assignee of the unfinished prerequisite and the epic's assignee" do
    blocker_assignee = member
    epic_assignee = member
    epic.update!(assignee: epic_assignee)
    blocker = create(:ticket, organization:, project:, assignee: blocker_assignee)
    create(:ticket_dependency, organization:, ticket: child, blocker:)

    notify

    expect(notices(blocker_assignee).sole.body).to include(blocker.code)
    expect(notices(epic_assignee).count).to eq(1)
    expect(notices(cto)).to be_empty
  end

  it "keeps the notice in the notification center only when ticket notices are switched off" do
    create(:alerting_preference, account: cto, organization:, tickets_enabled: false)
    create(:ticket_question, :blocking, :from_agent, organization:, ticket: child)

    notify

    expect(notices(cto).count).to eq(1)
    expect(notices(cto, via: :email)).to be_empty
  end

  it "emails the notice when ticket notices are on" do
    create(:ticket_question, :blocking, :from_agent, organization:, ticket: child)

    notify

    expect(notices(cto, via: :email).count).to eq(1)
  end
end
