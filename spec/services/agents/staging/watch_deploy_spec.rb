# frozen_string_literal: true

require "rails_helper"

# CYRA-1366 — with the trial-release rule off the merge opens production, and the trial release is watched
# until production starts: a failed or cancelled one stops the work, one never seen stops nothing.
RSpec.describe Agents::Staging::WatchDeploy do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) do
    create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails", default_branch: "main")
  end
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) do
    ticket.agent_workflow.tap do |w|
      w.update!(triage_started_at: 5.hours.ago, triaged_at: 4.hours.ago, planned_at: 4.hours.ago,
                approved_at: 3.hours.ago, autopilot_started_at: 3.hours.ago,
                autopilot_completed_at: 2.hours.ago, candidate_verified_at: 2.hours.ago,
                autopilot_approved_at: 2.hours.ago, closer_staging_started_at: 40.minutes.ago,
                closer_staging_completed_at: 30.minutes.ago, closer_staging_verified_at: 29.minutes.ago,
                closer_staging_next_check_at: 1.minute.ago, ticket_snapshot_digest: "snapshot")
    end
  end
  let!(:candidate) do
    create(:agent_delivery_candidate, :verified_passing, workflow:, organization:, repository:,
                                      repository_full_name: "bussolabs/closeyourit-rails",
                                      head_sha: "a" * 40, base_ref: "main").tap do |row|
      workflow.update!(review_candidate: row)
    end
  end

  before do
    create(:agent_attempt, workflow:, organization:, phase: "closer_staging", status: :approved,
                           result: { "code" => ticket.code, "state" => "staging-released",
                                     "tag" => "v1.0.0-beta.1", "commit" => "b" * 40 })
  end

  def job(name, conclusion) = { "name" => name, "conclusion" => conclusion }

  def client_with_runs(runs)
    instance_double(Github::Client).tap do |client|
      allow(client).to receive(:workflow_runs).and_return(runs.map { |id, conclusion, _| { "id" => id, "conclusion" => conclusion } })
      runs.each do |id, _, jobs|
        allow(client).to receive(:workflow_run_jobs).with(anything, anything, id).and_return(jobs)
      end
    end
  end

  let(:green_jobs) { [ job("ci / deploy-staging", "success"), job("ci / smoke-staging", "success") ] }
  let(:failed_jobs) { [ job("ci / deploy-staging", "success"), job("ci / smoke-staging", "failure") ] }
  let(:cancelled_jobs) { [ job("ci / deploy-staging", "cancelled"), job("ci / smoke-staging", "skipped") ] }

  # AC-3 — rule off, the trial release failed after the merge: the work stops and the card says so.
  it "stops the work before production when the trial release failed" do
    expect(project.staging_deploy_proof?).to be(false)

    described_class.call(workflow:, client: client_with_runs([ [ 1, "failure", failed_jobs ] ]))

    expect(workflow.reload).to have_attributes(blocked_kind: "staging_deploy", blocked_phase: "closer_production",
                                               closer_staging_next_check_at: nil)
    expect(workflow.ready_execution_phase).to be_nil
    stopped = I18n.with_locale(:it) do
      Member::AutomationSummary.new(workflow:, attempts: [], decides: true, cto_name: "Alessio").stopped
    end
    expect(stopped).to eq(I18n.t("member.tickets.automation.summary.stopped.staging_deploy.failed", locale: :it))
  end

  it "stops the work on a cancelled trial release too" do
    described_class.call(workflow:, client: client_with_runs([ [ 1, "cancelled", cancelled_jobs ] ]))

    expect(workflow.reload.blocked_kind).to eq("staging_deploy")
  end

  it "lets production go when another run on the same commit went fine" do
    client = client_with_runs([ [ 1, "cancelled", cancelled_jobs ], [ 2, "success", green_jobs ] ])

    described_class.call(workflow:, client:)

    expect(workflow.reload).to have_attributes(blocked_at: nil, closer_staging_next_check_at: nil)
    expect(workflow.ready_execution_phase).to eq("closer_production")
  end

  it "looks again in three minutes while the trial release is running" do
    described_class.call(workflow:, client: client_with_runs([]))

    expect(workflow.reload.blocked_at).to be_nil
    expect(workflow.closer_staging_next_check_at).to be_within(5.seconds).of(3.minutes.from_now)
  end

  # One never seen stops nothing: a project without a trial release keeps going to production.
  it "stops looking, without stopping the work, once the window is over" do
    workflow.update!(closer_staging_completed_at: 91.minutes.ago)

    described_class.call(workflow:, client: client_with_runs([]))

    expect(workflow.reload).to have_attributes(blocked_at: nil, closer_staging_next_check_at: nil)
  end

  it "looks again later when GitHub cannot be read" do
    client = instance_double(Github::Client)
    allow(client).to receive(:workflow_runs).and_raise(Github::Client::Error.new("boom", code: "github_timeout"))

    described_class.call(workflow:, client:)

    expect(workflow.reload.blocked_at).to be_nil
    expect(workflow.closer_staging_next_check_at).to be > Time.current
  end

  it "leaves alone a release whose production already started" do
    workflow.update!(closer_production_started_at: 1.minute.ago)
    client = instance_double(Github::Client)
    allow(client).to receive(:workflow_runs)

    described_class.call(workflow:, client:)

    expect(workflow.reload.blocked_at).to be_nil
    expect(client).not_to have_received(:workflow_runs)
  end
end
