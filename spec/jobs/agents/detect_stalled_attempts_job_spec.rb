# frozen_string_literal: true

require "rails_helper"

# CYRA-212 Scenario 2: il giro periodico che avvisa quando il sistema di automazione gira a vuoto.
RSpec.describe Agents::DetectStalledAttemptsJob, type: :job do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:now) { Time.current }

  it "delega al rilevatore e accoda l'allarme per l'org a vuoto" do
    create(:agent_host, organization:, last_heartbeat_at: now)
    create(:agent_attempt, organization:, workflow: create(:agent_workflow, organization:),
                           status: :stale, started_at: now - 2.hours, finished_at: now - 10.minutes)

    expect { described_class.perform_now }
      .to have_enqueued_job(Alerting::EvaluateJob)
      .with(hash_including(event_type: "agents_stalled", organization_id: organization.id))
  end

  it "non accoda nulla quando non c'è alcuno stallo" do
    create(:agent_host, organization:, last_heartbeat_at: now)

    expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end
end
