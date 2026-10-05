# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentAttemptSerializer do
  let(:organization) { create(:organization) }
  let(:workflow) { create(:agent_workflow, organization:) }
  let(:host) { create(:agent_host, organization:) }
  let(:service_account) do
    create(:account, :service).tap { |account| create(:membership, account:, organization:) }
  end

  it "espone identità + execution profile di un attempt host-first, con le colonne del profilo immutabili" do
    attempt = create(:agent_attempt, workflow:, organization:, host:,
                                     service_account:, skill_key: "/closeyourit-autopilot", runtime: "codex",
                                     phase: "autopilot", sandbox: "workspace-write", allowed_tools: [],
                                     ttl: 3600, bundle_digest: "sha256:abc", bundle_ref: "v1.0.0")

    json = JSON.parse(described_class.new(attempt).serialize)

    expect(json).to include(
      "phase" => "autopilot", "runtime" => "codex", "skill_key" => "/closeyourit-autopilot",
      "sandbox" => "workspace-write", "allowed_tools" => [], "ttl" => 3600,
      "bundle_digest" => "sha256:abc", "bundle_ref" => "v1.0.0",
      "host_id" => host.id, "service_account_id" => service_account.id,
      "ticket" => attempt.workflow.ticket.code
    )
  end
end
