# frozen_string_literal: true

require "rails_helper"

# CYRA-450: il giro periodico che avvisa quando una macchina di automazione è ferma da troppo.
RSpec.describe Agents::DetectStaleHostsJob, type: :job do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:now) { Time.current }

  it "delega al rilevatore e accoda l'allarme per la macchina ferma" do
    dead = create(:agent_host, organization:, last_heartbeat_at: now - 20.minutes,
                               heartbeat_expected_interval_minutes: 2, heartbeat_grace_minutes: 1)

    expect { described_class.perform_now }
      .to have_enqueued_job(Alerting::EvaluateJob)
      .with(hash_including(event_type: "agents_host_stale", subject_id: dead.id,
                           organization_id: organization.id))
  end

  it "non accoda nulla quando tutte le macchine sono vive" do
    create(:agent_host, organization:, last_heartbeat_at: now,
                        heartbeat_expected_interval_minutes: 2, heartbeat_grace_minutes: 1)

    expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end
end
