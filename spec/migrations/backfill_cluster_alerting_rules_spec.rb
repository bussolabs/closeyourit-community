# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261002152624_backfill_cluster_alerting_rules")

RSpec.describe BackfillClusterAlertingRules do
  let(:cluster_events) do
    %i[cluster_down cluster_up cluster_node_not_ready cluster_node_pressure cluster_workload_crashloop cluster_workload_degraded]
  end

  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it "installs the six cluster rules, enabled and organization-wide, on an organization without them" do
    organization = create(:organization)
    Alerting::Rule.where(organization:, event_type: cluster_events).delete_all

    run_backfill

    rules = Alerting::Rule.where(organization:, event_type: cluster_events)
    expect(rules.map(&:event_type)).to match_array(cluster_events.map(&:to_s))
    expect(rules).to all(be_enabled)
    expect(rules.map(&:project_id).uniq).to eq([ nil ])
  end

  it "is idempotent" do
    organization = create(:organization)
    run_backfill
    expect { run_backfill }.not_to change { Alerting::Rule.where(organization:).count }
  end
end
