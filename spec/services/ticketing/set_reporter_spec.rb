# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::SetReporter do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  # Eager: the factory reuses an existing member as reporter, so it must exist before the others.
  let!(:ticket) { create(:ticket, organization: org, project: project) }
  let(:actor) { ticket.reporter }

  def linked_member
    create(:account).tap do |account|
      create(:membership, account: account, organization: org, role: :member)
      create(:project_membership, account: account, project: project)
    end
  end

  def set_reporter(reporter_id)
    described_class.call(organization: org, ticket: ticket, reporter_id: reporter_id, actor: actor)
  end

  it "names a person who sees the project, records it and makes them a watcher" do
    client = linked_member

    expect(set_reporter(client.id)).to be_ok

    expect(ticket.reload.reporter).to eq(client)
    event = ticket.events.find_by(action: "reporter_changed")
    expect(event.data).to eq("reporter" => { "from" => actor.name, "to" => client.name })
    expect(ticket.subscriptions.find_by(account: client)).to be_source_reporter
  end

  it "keeps the previous reporter as a watcher" do
    Ticketing::Subscription.ensure_for(ticket: ticket, account: actor, source: :reporter)

    set_reporter(linked_member.id)

    expect(ticket.subscriptions.where(account: actor)).to exist
  end

  it "does nothing when the reporter is the same" do
    expect { set_reporter(actor.id) }.not_to change(Ticketing::Event, :count)
  end

  it "refuses a person who cannot see the project" do
    outsider = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }

    result = set_reporter(outsider.id)

    expect(result.error.code).to eq("R422-TICKET-023")
    expect(ticket.reload.reporter).to eq(actor)
  end

  it "refuses an empty choice: a ticket always has a reporter" do
    expect(set_reporter("")).to be_err
  end
end
