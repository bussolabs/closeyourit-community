# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::WebhookJob, type: :job do
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

  it "ignora gli eventi non gestiti" do
    expect { described_class.perform_now(event: "star", payload: {}) }.not_to raise_error
  end
end
