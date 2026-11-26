# frozen_string_literal: true

require "rails_helper"

# CYRA-1150 — Undo puts back exactly what the bulk action changed, and nothing someone changed since.
RSpec.describe Undo::Restore, type: :service do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization:) }

  def bulk(ids, action, model: Errors::BulkTriage, kind: "error_groups", scope: Errors::Group.all)
    Undo::Entry.capture(kind:, account:, organization:, ids:) { model.call(scope:, ids:, action:) }.last
  end

  it "gives back status, release and resolution notes of every group" do
    groups = Array.new(3) do
      create(:error_group, project:, status: :resolved, resolved_in_release: "2.1",
                           resolution_cause: "cache miss", resolution_fix: "warm up")
    end
    entry = bulk(groups.map(&:id), "reopen")

    result = described_class.call(entry:, ids: groups.map(&:id))

    expect(result.value.restored_ids).to match_array(groups.map(&:id))
    expect(result.value.kept).to eq(0)
    groups.each do |group|
      expect(group.reload).to have_attributes(status: "resolved", resolved_in_release: "2.1",
                                              resolution_cause: "cache miss", resolution_fix: "warm up")
    end
  end

  it "leaves alone a group someone changed after the action" do
    kept, back = create_list(:error_group, 2, project:, status: :unresolved)
    entry = bulk([ kept.id, back.id ], "ignore")
    Errors::Triage.call(group: kept.reload, action: "resolve")

    result = described_class.call(entry:, ids: [ kept.id, back.id ])

    expect(result.value.restored_ids).to eq([ back.id ])
    expect(result.value.kept).to eq(1)
    expect(kept.reload).to be_status_resolved
    expect(back.reload).to be_status_unresolved
  end

  it "does not touch a group a returning error reopened" do
    group = create(:error_group, project:, status: :unresolved)
    entry = bulk([ group.id ], "resolve")
    Errors::Group.where(id: group.id).update_all(status: Errors::Group.statuses["unresolved"], regressed_in_release: "3.0") # rubocop:disable Rails/SkipsModelValidations

    result = described_class.call(entry:, ids: [ group.id ])

    expect(result.value.kept).to eq(1)
    expect(group.reload.regressed_in_release).to eq("3.0")
  end

  it "skips the rows the actor may no longer change" do
    group = create(:error_group, project:, status: :unresolved)
    entry = bulk([ group.id ], "ignore")

    result = described_class.call(entry:, ids: [])

    expect(result.value.kept).to eq(1)
    expect(group.reload).to be_status_ignored
  end

  it "puts back slowness groups" do
    groups = create_list(:metric_group, 3, project:, status: :unresolved)
    entry = bulk(groups.map(&:id), "ignore", model: Metrics::BulkTriage, kind: "metric_groups", scope: Metrics::Group.all)

    described_class.call(entry:, ids: groups.map(&:id))

    expect(groups.map { |group| group.reload.status }).to all(eq("unresolved"))
  end

  it "spends the entry: a second undo finds nothing" do
    group = create(:error_group, project:, status: :unresolved)
    entry = bulk([ group.id ], "resolve")

    described_class.call(entry:, ids: [ group.id ])

    expect(Undo::Entry.exists?(entry.id)).to be(false)
  end
end
