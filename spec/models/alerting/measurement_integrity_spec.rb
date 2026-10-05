# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Measurement evaluation storage integrity" do
  let(:project) { create(:project) }
  let(:rule) { create(:alerting_rule, project: project, organization: project.organization) }
  let(:attributes) { { rule_id: rule.id, project_id: project.id, series_id: SecureRandom.uuid, config_digest: "a" * 64, window_end_ns: (2**64) - 1, result: {}, status: "unknown" } }

  it "round-trips uint64 windows exactly and rejects duplicate window identities" do
    row = Alerting::Evaluation.create!(attributes)
    expect(row.reload.window_end_ns.to_i).to eq((2**64) - 1)
    expect { Alerting::Evaluation.transaction(requires_new: true) { Alerting::Evaluation.create!(attributes) } }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { Alerting::Evaluation.transaction(requires_new: true) { Alerting::Evaluation.create!(attributes.merge(window_end_ns: 2**64)) } }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "enforces project binding independently of service validation" do
    other = create(:project)
    expect { Alerting::Evaluation.transaction(requires_new: true) { Alerting::Evaluation.create!(attributes.merge(project_id: other.id)) } }.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
