# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::LinkSignals do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:owner) { create(:account).tap { |account| create(:membership, account: account, organization: org, role: :owner) } }
  let(:ticket) { create(:ticket, organization: org, project: project, kind: :bug) }
  let(:error_group) { create(:error_group, project: project) }
  let(:metric_group) { create(:metric_group, project: project) }

  def link(actor: owner, **ids)
    described_class.call(ticket: ticket, actor: actor, organization: org, **ids)
  end

  it "links the chosen error and performance group to a bug" do
    link(error_group_id: error_group.id, metric_group_id: metric_group.id)

    expect(error_group.reload.ticket).to eq(ticket)
    expect(metric_group.reload.ticket).to eq(ticket)
  end

  it "does nothing when nothing was chosen" do
    expect(link(error_group_id: "", metric_group_id: nil)).to eq([])
  end

  it "ignores the choice on a ticket that is not a bug" do
    ticket.update!(kind: :task)

    link(error_group_id: error_group.id)

    expect(error_group.reload.ticket).to be_nil
  end

  it "ignores a group of another project" do
    foreign = create(:error_group, project: create(:project, organization: org))

    link(error_group_id: foreign.id)

    expect(foreign.reload.ticket).to be_nil
  end

  it "leaves a group that already has a ticket alone" do
    other = create(:ticket, organization: org, project: project)
    error_group.update!(ticket: other)

    link(error_group_id: error_group.id)

    expect(error_group.reload.ticket).to eq(other)
  end

  it "ignores the choice of someone who may not promote on the project" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)

    link(actor: member, error_group_id: error_group.id, metric_group_id: metric_group.id)

    expect(error_group.reload.ticket).to be_nil
    expect(metric_group.reload.ticket).to be_nil
  end
end
