# frozen_string_literal: true

require "rails_helper"

RSpec.describe Crons::EvaluateJob, type: :job do
  include ActiveJob::TestHelper

  let(:project) { create(:project) }
  let(:now) { Time.utc(2026, 7, 2, 12) }

  it "monitor scaduto → missed + alert cron_missed (una volta)" do
    monitor = create(:cron_monitor, project:, expected_interval_minutes: 60, grace_minutes: 5,
                                    status: :ok, last_check_in_at: now - 2.hours)

    expect { described_class.perform_now(now:) }
      .to have_enqueued_job(Alerting::EvaluateJob)
      .with(hash_including(event_type: "cron_missed", subject_type: "Crons::Monitor", subject_id: monitor.id))

    expect(monitor.reload).to be_status_missed
    expect(monitor.missed_alerted_at).to be_within(1).of(now)
  end

  it "monitor già missed → non ri-avvisa" do
    create(:cron_monitor, project:, status: :missed, last_check_in_at: now - 2.hours)
    expect { described_class.perform_now(now:) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "monitor nella finestra → nessun alert, resta ok" do
    monitor = create(:cron_monitor, project:, expected_interval_minutes: 60, grace_minutes: 5,
                                    status: :ok, last_check_in_at: now - 10.minutes)
    expect { described_class.perform_now(now:) }.not_to have_enqueued_job(Alerting::EvaluateJob)
    expect(monitor.reload).to be_status_ok
  end

  it "monitor disabilitato scaduto → ignorato" do
    create(:cron_monitor, project:, enabled: false, status: :ok, last_check_in_at: now - 2.hours)
    expect { described_class.perform_now(now:) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  describe "broadcast realtime" do
    let(:organization) { project.organization }
    let(:crons_stream) { Realtime::Streams.crons(organization) }
    let(:project_stream) { Realtime::Streams.project_crons(project) }

    def overdue_monitor(proj = project)
      create(:cron_monitor, project: proj, expected_interval_minutes: 60, grace_minutes: 5,
                            status: :ok, last_check_in_at: now - 2.hours)
    end

    it "2 overdue monitors, same org: one row + labels per monitor on the project stream, one refresh on the org" do
      monitor_a = overdue_monitor
      monitor_b = overdue_monitor

      expect { described_class.perform_now(now:) }
        .to have_broadcasted_to(project_stream).exactly(2).times # 2 rows (CYRA-1040)
        .and have_broadcasted_to(crons_stream).once               # 1 refresh for the pills
        .and have_broadcasted_to(Realtime::Streams.cron_monitor(monitor_a)).once
        .and have_broadcasted_to(Realtime::Streams.cron_monitor(monitor_b)).once
    end

    it "la riga colpisce il dom_id del monitor; le pill arrivano da un refresh (CYRA-257)" do
      monitor = overdue_monitor

      expect { described_class.perform_now(now:) }
        .to have_broadcasted_to(project_stream).with(a_string_including("crons_monitor_#{monitor.id}"))
        .and have_broadcasted_to(crons_stream).with(a_string_including(%(action="refresh")))
    end

    it "monitor scaduti in org diverse: ciascuno sul proprio stream, mai su quello altrui" do
      other_project = create(:project)
      overdue_monitor
      overdue_monitor(other_project)

      expect { described_class.perform_now(now:) }
        .to have_broadcasted_to(project_stream).once                                   # 1 row
        .and have_broadcasted_to(crons_stream).once                                    # 1 refresh
        .and have_broadcasted_to(Realtime::Streams.project_crons(other_project)).once
        .and have_broadcasted_to(Realtime::Streams.crons(other_project.organization)).once
    end

    it "nessun monitor scaduto: nessun broadcast" do
      create(:cron_monitor, project:, status: :ok, last_check_in_at: now - 10.minutes)

      expect { described_class.perform_now(now:) }.not_to have_broadcasted_to(crons_stream)
    end
  end
end
