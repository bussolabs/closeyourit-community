# frozen_string_literal: true

require "rails_helper"

# CYRA-1162 — every ticket a person brings to done counts toward the referral prompt threshold.
RSpec.describe Ticketing::ChangeStatus, "closed tickets count" do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:open_status) { create(:ticket_status, organization: org) }
  let(:done_status) { create(:ticket_status, :done, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project:, status: open_status) }
  let(:person) { create(:account) }

  def closed_count(account) = Accounts::ReferralPrompt.where(account:).pick(:closed_tickets_count) || 0

  def move(to, **options)
    described_class.call(organization: org, ticket:, status_id: to.id,
                         **{ channel: :web, actor: person, true_actor: person }.merge(options))
  end

  it "adds one when a person brings a ticket to done" do
    expect(move(done_status)).to be_ok

    expect(closed_count(person)).to eq(1)
  end

  it "does not take one back when the ticket is reopened, nor count a move between two done statuses" do
    move(done_status)
    move(open_status)
    move(done_status)
    move(create(:ticket_status, :done, organization: org))

    expect(closed_count(person)).to eq(2)
  end

  it "does not count the system's own moves" do
    move(done_status, channel: :workflow)

    expect(closed_count(person)).to eq(0)
  end

  it "does not count a machine" do
    machine = create(:account, :service)
    described_class.call(organization: org, ticket:, status_id: done_status.id, channel: :cli, actor: machine,
                         true_actor: machine)

    expect(closed_count(machine)).to eq(0)
  end

  it "does not count a close made while someone stands in for the person" do
    move(done_status, true_actor: create(:account, god: true))

    expect(closed_count(person)).to eq(0)
  end
end
