# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Workflows::BackfillHostAttribution do
  let(:organization) { create(:organization) }
  let(:workflow) { create(:agent_workflow, organization:) }
  let(:host) { create(:agent_host, organization:) }
  let(:service_account) do
    create(:account, :service).tap { |account| create(:membership, account:, organization:) }
  end

  def host_first_attempt(phase:, host:, service_account:, **overrides)
    create(:agent_attempt, workflow:, organization:, host:, service_account:,
                           skill_key: "/closeyourit-#{phase}", runtime: "codex", phase:, **overrides)
  end

  def legacy_attempt(phase:, host:, **overrides)
    create(:agent_attempt, workflow:, organization:, host:, phase:, **overrides)
  end

  it "attribuisce host e service account alla fase dall'attempt host-first" do
    host_first_attempt(phase: "autopilot", host:, service_account:)

    described_class.call

    workflow.reload
    expect(workflow.autopilot_by_host).to eq(host)
    expect(workflow.autopilot_by_service_account).to eq(service_account)
  end


  it "con più tentativi della stessa fase prende l'ULTIMO per created_at" do
    old_host = create(:agent_host, organization:)
    new_host = create(:agent_host, organization:)
    host_first_attempt(phase: "triage", host: old_host, service_account:, created_at: 3.hours.ago)
    host_first_attempt(phase: "triage", host: new_host, service_account:, created_at: 1.hour.ago)

    described_class.call

    expect(workflow.reload.triage_by_host).to eq(new_host)
  end

  it "lascia a nil le colonne di una fase senza tentativi" do
    host_first_attempt(phase: "triage", host:, service_account:)

    described_class.call

    workflow.reload
    expect(workflow.autopilot_by_host).to be_nil
    expect(workflow.autopilot_by_service_account).to be_nil
  end

  it "mappa la fase 'planner' sulle colonne planned_by_* (asimmetria di naming)" do
    host_first_attempt(phase: "planner", host:, service_account:)

    described_class.call

    workflow.reload
    expect(workflow.planned_by_host).to eq(host)
    expect(workflow.planned_by_service_account).to eq(service_account)
  end

  it "è idempotente (una seconda esecuzione non cambia il risultato)" do
    host_first_attempt(phase: "closer_staging", host:, service_account:)

    described_class.call
    described_class.call

    workflow.reload
    expect(workflow.closer_staging_by_host).to eq(host)
    expect(workflow.closer_staging_by_service_account).to eq(service_account)
  end

  it "non tocca gli altri workflow (expand-only)" do
    other_workflow = create(:agent_workflow, organization:)
    attempt = legacy_attempt(phase: "triage", host:)

    described_class.call

    workflow.reload
    expect(other_workflow.reload.triage_by_host_id).to be_nil
  end

  it "non crea né elimina workflow (conteggi pre/post invariati)" do
    host_first_attempt(phase: "autopilot", host:, service_account:)

    expect { described_class.call }.not_to change(Agents::Workflow, :count)
  end
end
