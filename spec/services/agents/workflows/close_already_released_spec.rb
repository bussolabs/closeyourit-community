# frozen_string_literal: true

require "rails_helper"

# Approved work whose code already went out with a later release proved in production: the closers
# have nothing left to release, so the workflow closes as released instead of waiting for a person.
RSpec.describe Agents::Workflows::CloseAlreadyReleased do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:, full_name: "bussolabs/app") }
  let!(:done) { create(:ticket_status, :done, organization:) }
  let(:in_progress) { create(:ticket_status, :in_progress, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, status: in_progress, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:head_sha) { "a" * 40 }
  let(:release_sha) { "b" * 40 }
  let(:candidate) do
    create(:agent_delivery_candidate, :verified_passing, workflow:, organization:, repository:,
                                                         repository_full_name: "bussolabs/app", number: 12, head_sha:)
  end

  before do
    pronta_per!(workflow, "closer_staging")
    workflow.update!(review_candidate_id: candidate.id)
    create(:github_pull_request, repository:, number: 12, state: :merged, merged_at: 1.hour.ago)
    project.releases.create!(version: "v1.4.0", environment: "production", sha: release_sha, proved_at: 10.minutes.ago)
  end

  def client(contained:)
    instance_double(Github::Client).tap { |c| allow(c).to receive(:commit_contained?).and_return(contained) }
  end

  it "closes the workflow as released when the proved release contains the approved code" do
    c = client(contained: true)

    described_class.call(workflow:, client: c)

    expect(workflow.reload.completed_at).to be_present
    expect(ticket.reload.status).to eq(done)
    expect(c).to have_received(:commit_contained?)
      .with(repository.installation.installation_id, "bussolabs/app", release_sha, head_sha)
  end

  it "also closes a workflow that stopped in the closers" do
    workflow.update!(blocked_at: Time.current, blocked_phase: "closer_staging", blocked_reason: "release.sh failed",
                     blocked_kind: "agent_blocked")

    described_class.call(workflow:, client: client(contained: true))

    expect(workflow.reload).to have_attributes(completed_at: be_present, blocked_at: nil)
  end

  it "leaves the workflow alone when the release does not contain the approved code" do
    described_class.call(workflow:, client: client(contained: false))

    expect(workflow.reload.completed_at).to be_nil
  end

  it "does not ask GitHub while the approved pull request is not merged" do
    Github::PullRequest.update_all(state: Github::PullRequest.states[:open], merged_at: nil)
    c = instance_double(Github::Client)

    described_class.call(workflow:, client: c)

    expect(workflow.reload.completed_at).to be_nil
  end

  # Projects proved by "merge" record their releases without a proved commit: the stable tag is the evidence.
  it "reads the commit of the latest stable tag when no release was proved" do
    project.releases.update_all(proved_at: nil, sha: nil)
    c = client(contained: true)
    allow(c).to receive(:tag_commit).and_return(release_sha)

    described_class.call(workflow:, client: c)

    expect(workflow.reload.completed_at).to be_present
    expect(c).to have_received(:tag_commit).with(repository.installation.installation_id, "bussolabs/app", "v1.4.0")
  end

  it "ignores a beta tag recorded as the latest release" do
    project.releases.update_all(proved_at: nil, sha: nil, version: "v1.5.0-beta.1")
    c = instance_double(Github::Client)

    described_class.call(workflow:, client: c)

    expect(workflow.reload.completed_at).to be_nil
  end

  it "ignores work a person has not approved yet" do
    workflow.update!(autopilot_approved_at: nil)
    c = instance_double(Github::Client)

    described_class.call(workflow:, client: c)

    expect(workflow.reload.completed_at).to be_nil
  end
end
