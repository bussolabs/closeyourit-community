# frozen_string_literal: true

require "rails_helper"

# CYRA-147 — giro giornaliero dei promemoria di scadenza. Accoda l'allarme org-scoped workload_due_soon
# per ogni attività aperta in scadenza; i destinatari (partecipanti) li risolve Evaluate dal subject.
RSpec.describe Workload::DueReminderJob, type: :job do
  include ActiveJob::TestHelper

  it "accoda workload_due_soon org-scoped per un'attività aperta in scadenza" do
    action = create(:workload_action, status: :planned, due_at: 12.hours.from_now)

    expect { described_class.new.perform }
      .to have_enqueued_job(Alerting::EvaluateJob).with(
        hash_including(event_type: "workload_due_soon", subject_type: "Workload::Action",
                       subject_id: action.id, project_id: nil,
                       organization_id: action.team.organization_id)
      )
  end

  it "non accoda nulla per attività chiuse o con scadenza lontana" do
    create(:workload_action, :done, due_at: 12.hours.from_now)
    create(:workload_action, status: :planned, due_at: 1.week.from_now)

    expect { described_class.new.perform }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "gira sulla coda :notifications" do
    expect(described_class.new.queue_name).to eq("notifications")
  end
end
