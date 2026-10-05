# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260809100000_backfill_analytics_idea_workload_dataset_alerting_rules")

RSpec.describe BackfillAnalyticsIdeaWorkloadDatasetAlertingRules do
  # CYRA-147: i tipi installati di default sulle org ESISTENTI, gli stessi di Alerting::Rules::InstallDefaults.
  # Il picco di traffico (analytics_traffic_spike) resta opt-in e non compare qui.
  let(:new_events) do
    %w[analytics_traffic_drop idea_created idea_commented workload_due_soon
       dataset_training_completed dataset_training_failed]
  end

  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it "installa le regole statistiche/idee/attività/dataset org-wide e attive su un'org esistente senza regole" do
    org = create(:organization)

    run_backfill

    rules = Alerting::Rule.where(organization: org)
    expect(rules.map(&:event_type)).to contain_exactly(*new_events)
    expect(rules).to all(be_enabled)
    expect(rules.map(&:project_id).uniq).to eq([ nil ])
    expect(rules.map(&:environment_id).uniq).to eq([ nil ])
    expect(rules.map(&:threshold).uniq).to eq([ nil ])
  end

  it "NON installa il picco di traffico (opt-in, spesso benigno)" do
    org = create(:organization)

    run_backfill

    expect(Alerting::Rule.where(organization: org, event_type: :analytics_traffic_spike)).not_to exist
  end

  it "è idempotente (rieseguibile senza duplicare)" do
    org = create(:organization)

    2.times { run_backfill }

    expect(Alerting::Rule.where(organization: org).count).to eq(new_events.size)
    expect(Alerting::Rule.where(organization: org, event_type: :idea_created).count).to eq(1)
  end

  it "non tocca una regola idea_created org-wide già configurata a mano, anche se disabilitata" do
    org = create(:organization)
    existing = create(:alerting_rule, :disabled, organization: org, event_type: :idea_created,
                      name: "Le mie idee")

    run_backfill

    ideas = Alerting::Rule.where(organization: org, event_type: :idea_created)
    expect(ideas.count).to eq(1)
    expect(existing.reload).not_to be_enabled
    expect(existing.name).to eq("Le mie idee")
  end

  it "installa comunque idea_created org-wide se ne esiste solo una scoped su un progetto (gli altri resterebbero scoperti)" do
    org = create(:organization)
    create(:alerting_rule, :scoped, organization: org, event_type: :idea_created)

    run_backfill

    org_wide = Alerting::Rule.where(organization: org, event_type: :idea_created,
                                    project_id: nil, environment_id: nil)
    expect(org_wide.count).to eq(1)
    expect(org_wide.first).to be_enabled
  end

  it "non duplica workload_due_soon: una regola scoped conta già come installata (Evaluate ignora lo scope)" do
    org = create(:organization)
    scoped = create(:alerting_rule, :scoped, organization: org, event_type: :workload_due_soon)

    run_backfill

    dues = Alerting::Rule.where(organization: org, event_type: :workload_due_soon)
    expect(dues.count).to eq(1)
    expect(dues.first).to eq(scoped)
  end

  it "copre tutte le org esistenti" do
    org_a = create(:organization)
    org_b = create(:organization)

    run_backfill

    [ org_a, org_b ].each do |org|
      expect(Alerting::Rule.where(organization: org).map(&:event_type)).to contain_exactly(*new_events)
    end
  end
end
