# frozen_string_literal: true

require "rails_helper"

# CYRA-1146 — opening a page marks as read the viewer's own in-app notifications about what it shows.
RSpec.describe Notifications::MarkRead do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:account) { create(:account) }
  let(:group) { create(:error_group, project: project) }
  let(:stream) { "alerting:notifications:#{account.id}" }

  def notification(**attributes)
    create(:alerting_notification, :unread, organization: organization, account: account, subject: group, **attributes)
  end

  def mark(subjects) = described_class.call(account: account, organization: organization, subjects: subjects)

  it "marks the account's unread in-app notifications on the subject as read" do
    mine = [ notification, notification(event_type: :error_regression) ]

    expect(mark([ group ])).to eq(2)
    expect(mine.map { |n| n.reload.read? }).to all(be(true))
  end

  it "leaves other people, other organizations, other channels and other subjects alone" do
    colleague = notification(account: create(:account))
    elsewhere = notification(organization: create(:organization))
    by_email = notification(via: :email)
    other_subject = notification(subject: create(:error_group, project: project))

    mark([ group ])

    expect([ colleague, elsewhere, by_email, other_subject ].map { |n| n.reload.read? }).to all(be(false))
  end

  it "accepts a relation to cover many subjects of one kind" do
    monitor = create(:uptime_monitor, project: project)
    incidents = create_list(:uptime_incident, 2, monitor: monitor)
    on_incidents = incidents.map { |incident| notification(subject: incident, event_type: :uptime_down) }
    on_monitor = notification(subject: monitor, event_type: :uptime_slow)

    expect(mark([ monitor, monitor.incidents ])).to eq(3)
    expect([ *on_incidents, on_monitor ].map { |n| n.reload.read? }).to all(be(true))
  end

  it "pushes the new unread count of this organization to the open tabs" do
    notification
    notification(subject: create(:error_group, project: project))

    expect { mark([ group ]) }.to have_broadcasted_to(stream).exactly(:once)
  end

  it "pushes nothing when no notification changes" do
    notification(read_at: 1.hour.ago)

    expect { expect(mark([ group ])).to eq(0) }.not_to have_broadcasted_to(stream)
  end
end
