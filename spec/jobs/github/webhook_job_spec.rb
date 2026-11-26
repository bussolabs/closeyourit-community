# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::WebhookJob, type: :job do
  include ActiveJob::TestHelper

  it "dispatcha l'evento push all'handler Push" do
    payload = { "ref" => "refs/tags/v1.0.0" }
    expect(Github::Webhooks::Push).to receive(:call).with(payload:)
    described_class.perform_now(event: "push", payload:)
  end

  it "dispatcha l'evento create all'handler Create" do
    payload = { "ref_type" => "tag" }
    expect(Github::Webhooks::Create).to receive(:call).with(payload:)
    described_class.perform_now(event: "create", payload:)
  end

  it "dispatcha l'evento release all'handler Release" do
    payload = { "action" => "published" }
    expect(Github::Webhooks::Release).to receive(:call).with(payload:)
    described_class.perform_now(event: "release", payload:)
  end

  it "dispatcha l'evento installation all'handler Installation" do
    payload = { "action" => "deleted" }
    expect(Github::Webhooks::Installation).to receive(:call).with(payload:)
    described_class.perform_now(event: "installation", payload:)
  end

  it "dispatcha l'evento pull_request all'handler PullRequest" do
    payload = { "action" => "opened" }
    expect(Github::Webhooks::PullRequest).to receive(:call).with(payload:)
    described_class.perform_now(event: "pull_request", payload:)
  end

  # CYRA-1055 — issues, comments and board cards go one at a time per issue, keyed by its node id.
  it "queues the issue events per issue, keyed by the issue's node id" do
    payload = { "action" => "opened", "issue" => { "node_id" => "I_7" } }

    expect { described_class.perform_now(event: "issues", payload:) }
      .to have_enqueued_job(Github::Issues::EventJob).with(event: "issues", payload:, key: "I_7")
  end

  it "keys a board card by the issue it carries" do
    payload = { "action" => "edited", "projects_v2_item" => { "node_id" => "PVTI_1", "content_node_id" => "I_7" } }

    expect { described_class.perform_now(event: "projects_v2_item", payload:) }
      .to have_enqueued_job(Github::Issues::EventJob).with(event: "projects_v2_item", payload:, key: "I_7")
  end

  it "dispatches the workflow_job event to the WorkflowJob handler" do
    payload = { "action" => "completed" }
    expect(Github::Webhooks::WorkflowJob).to receive(:call).with(payload:)
    described_class.perform_now(event: "workflow_job", payload:)
  end

  it "keeps issue receipts unfinished until their serialized handler succeeds, including duplicate jobs" do
    payload = { "action" => "opened", "issue" => { "node_id" => "I_7" } }
    receipt = Github::WebhookDelivery.receive(delivery_id: "issue", event: "issues", body: payload.to_json)
    expect(Github::Webhooks::Issues).to receive(:call).once.with(payload:)

    2.times { described_class.perform_now(delivery_id: receipt.id) }
    expect(receipt.reload.completed_at).to be_nil
    expect(receipt.body).to be_present
    expect(Github::Issues::EventJob).to have_been_enqueued.with(event: "issues", payload: {}, key: "I_7", delivery_id: receipt.id).twice

    perform_enqueued_jobs
    expect(receipt.reload.completed_at).to be_present
    expect(receipt.body).to be_nil
    expect { described_class.perform_now(delivery_id: receipt.id) }.not_to have_enqueued_job(Github::Issues::EventJob)
  end

  it "recovers an issue receipt when its serialized handler returns a failure" do
    receipt = Github::WebhookDelivery.receive(delivery_id: "issue", event: "issues", body: '{"issue":{"node_id":"I_7"}}')
    allow(Github::Webhooks::Issues).to receive(:call).and_return(double(ok?: false))

    described_class.perform_now(delivery_id: receipt.id)
    clear_enqueued_jobs
    expect { Github::Issues::EventJob.perform_now(event: "issues", payload: {}, key: "I_7", delivery_id: receipt.id) }
      .to raise_error("GitHub webhook handler failed")
    expect(receipt.reload.completed_at).to be_nil
    expect(receipt.body).to be_present

    allow(Github::Webhooks::Issues).to receive(:call).and_return(double(ok?: true))
    perform_enqueued_jobs { Github::RecoverWebhooksJob.perform_now }
    expect(receipt.reload.completed_at).to be_present
  end

  it "ignora gli eventi non gestiti" do
    expect { described_class.perform_now(event: "star", payload: {}) }.not_to raise_error
  end

  it "dispatches a receipt once and removes its body only after success" do
    receipt = Github::WebhookDelivery.receive(delivery_id: "one", event: "installation", body: '{"action":"created"}')
    expect(Github::Webhooks::Installation).to receive(:call).once.with(payload: { "action" => "created" })
    2.times { described_class.perform_now(delivery_id: receipt.id) }
    expect(receipt.reload.completed_at).to be_present
    expect(receipt.body).to be_nil
  end

  it "does not complete a failed handler and allows recovery" do
    receipt = Github::WebhookDelivery.receive(delivery_id: "one", event: "installation", body: "{}")
    allow(Github::Webhooks::Installation).to receive(:call).and_raise("interrupted")
    expect { described_class.perform_now(delivery_id: receipt.id) }.to raise_error("interrupted")
    expect(receipt.reload.completed_at).to be_nil
    allow(Github::Webhooks::Installation).to receive(:call).and_call_original
    perform_enqueued_jobs { Github::RecoverWebhooksJob.perform_now }
    expect(receipt.reload.completed_at).to be_present
  end

  it "does not mark unsuccessful service results as completed" do
    receipt = Github::WebhookDelivery.receive(delivery_id: "one", event: "installation", body: "{}")
    allow(Github::Webhooks::Installation).to receive(:call).and_return(double(ok?: false))
    expect { described_class.perform_now(delivery_id: receipt.id) }.to raise_error("GitHub webhook handler failed")
    expect(receipt.reload.completed_at).to be_nil
    expect(receipt.body).to eq("{}")
  end

  it "does not manufacture a signed receipt for legacy jobs" do
    expect { described_class.perform_now(event: "star", payload: {}) }.not_to change(Github::WebhookDelivery, :count)
  end

  it "preserves a recreated installation when a completed deletion returns a year later" do
    repository = create(:github_repository)
    installation = repository.installation
    organization = installation.organization
    github_id = installation.installation_id
    body = { action: "deleted", installation: { id: github_id } }.to_json
    receipt = Github::WebhookDelivery.receive(delivery_id: "old", event: "installation", body:)
    described_class.perform_now(delivery_id: receipt.id)
    expect(Github::Installation.exists?(installation.id)).to be(false)
    expect(Github::Repository.exists?(repository.id)).to be(false)
    replacement = create(:github_installation, organization:, installation_id: github_id)

    travel_to 1.year.from_now do
      replay = Github::WebhookDelivery.receive(delivery_id: "changed", event: "installation", body:)
      described_class.perform_now(delivery_id: replay.id)
      expect(Github::Installation.exists?(replacement.id)).to be(true)
    end
  end
end
