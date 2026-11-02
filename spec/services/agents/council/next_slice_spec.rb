# spec/services/agents/council/next_slice_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Council::NextSlice do
  let(:organization) { create(:organization) }
  let(:service_account) do
    create(:account, :service).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end
  let(:host) { create(:agent_host, organization:, service_account:) }
  let!(:setting) { create(:agent_automator_setting, organization:, council_mode: "on") }
  let!(:project) { create(:project, organization:, council_enabled: true) }

  def slice = described_class.call(host:).value

  it "opens a run on an active project and returns its data" do
    item = slice
    run = Agents::CouncilRun.find(item[:run_id])
    expect(run).to have_attributes(project:, host:, mode: "on", status: "running")
    expect(item).to include(project_key: project.key, max_proposals: 3, engines: %w[claude codex])
    expect(item[:signals].keys).to contain_exactly(:errors, :slow, :monitors_down)
  end

  it "returns nothing when the council is off" do
    setting.update!(council_mode: "off")
    expect(slice).to be_nil
  end

  it "returns nothing while another slice of the organization runs" do
    create(:agent_council_run, organization:, project: create(:project, organization:), host:)
    expect(slice).to be_nil
  end

  it "returns nothing when another machine takes the running slot first" do
    allow(Agents::CouncilRun).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)
    expect { expect(slice).to be_nil }.not_to raise_error
  end

  it "closes a slice running for more than two hours as abandoned" do
    stale = create(:agent_council_run, organization:, project:, host:, started_at: 3.hours.ago)
    expect(slice).to be_nil # the project had a slice in the last 24 hours
    expect(stale.reload).to have_attributes(status: "failed", failure_kind: "abandoned")
  end

  it "waits a day after a quota failure" do
    create(:agent_council_run, organization:, project: create(:project, organization:), host:,
                               status: "failed", failure_kind: "quota", started_at: 1.hour.ago)
    expect(slice).to be_nil
  end

  it "skips a project looked at in the last 24 hours" do
    create(:agent_council_run, organization:, project:, host:, status: "completed", started_at: 5.hours.ago)
    expect(slice).to be_nil
  end

  it "picks the project looked at least recently" do
    newer = create(:project, organization:, council_enabled: true)
    create(:agent_council_run, organization:, project:, host:, status: "completed", started_at: 30.hours.ago)
    create(:agent_council_run, organization:, project: newer, host:, status: "completed", started_at: 26.hours.ago)
    expect(slice[:project_key]).to eq(project.key)
  end

  it "lists unresolved errors and open tickets" do
    create(:error_group, project:, title: "NoMethodError in TicketsController", status: :unresolved)
    create(:ticket, organization:, project:, title: "Speed up search")
    item = slice
    expect(item[:signals][:errors].map { |e| e[:title] }).to include("NoMethodError in TicketsController")
    expect(item[:open_tickets].map { |t| t[:title] }).to include("Speed up search")
  end
end
