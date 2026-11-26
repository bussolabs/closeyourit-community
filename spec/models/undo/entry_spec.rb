# frozen_string_literal: true

require "rails_helper"

# CYRA-1150 — the undo log of a bulk action: what changed, before and after, recorded with the action.
RSpec.describe Undo::Entry, type: :model do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization:) }

  def capture(ids, kind: "error_groups", &)
    described_class.capture(kind:, account:, organization:, ids:, &)
  end

  it "records every written column before and after, only for the rows the action changed" do
    resolved = create(:error_group, project:, status: :resolved, resolved_in_release: "1.0",
                                    resolution_cause: "nil total", resolution_fix: "guard")
    open = create(:error_group, project:, status: :unresolved)

    value, entry = capture([ resolved.id, open.id ]) do
      Errors::BulkTriage.call(scope: Errors::Group.all, ids: [ resolved.id, open.id ], action: "reopen")
    end

    expect(value).to be_ok
    expect(entry.items.size).to eq(1)
    item = entry.items.first
    expect(item["id"]).to eq(resolved.id)
    expect(item["before"]).to include("status" => "resolved", "resolved_in_release" => "1.0",
                                      "resolution_cause" => "nil total", "resolution_fix" => "guard")
    expect(item["after"]).to include("status" => "unresolved", "resolution_cause" => nil, "resolution_fix" => nil)
    expect(entry.expires_at).to be_within(1.second).of(described_class::TTL.from_now)
  end

  it "leaves no entry when the action changed nothing" do
    group = create(:error_group, project:, status: :resolved)

    _, entry = capture([ group.id ]) { Errors::BulkTriage.call(scope: Errors::Group.all, ids: [ group.id ], action: "resolve") }

    expect(entry).to be_nil
    expect(described_class.count).to eq(0)
  end

  it "keeps read times at the database precision, so the comparison holds after a round trip" do
    notification = create(:alerting_notification, organization:, account:, read_at: nil)

    _, entry = capture([ notification.id ], kind: "notifications") do
      Alerting::Notification.where(id: notification.id).update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    expect(entry.items.first["after"]).to eq(described_class.snapshot(notification.reload, "notifications"))
  end

  it "counts as expired once its time is over" do
    entry = described_class.create!(kind: "metric_groups", account:, organization:, items: [], expires_at: 1.second.from_now)

    expect(entry).not_to be_expired
    travel 2.seconds do
      expect(entry).to be_expired
      expect(described_class.expired).to contain_exactly(entry)
    end
  end
end
