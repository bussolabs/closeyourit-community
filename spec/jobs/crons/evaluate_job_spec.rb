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

    def overdue_monitor(proj = project)
      create(:cron_monitor, project: proj, expected_interval_minutes: 60, grace_minutes: 5,
                            status: :ok, last_check_in_at: now - 2.hours)
    end

    it "2 monitor scaduti stessa org: una riga + labels per monitor, pill UNA sola volta (2+1 = 3 sul crons)" do
      monitor_a = overdue_monitor
      monitor_b = overdue_monitor

      expect { described_class.perform_now(now:) }
        .to have_broadcasted_to(crons_stream).exactly(3).times   # 2 righe + 1 refresh pill
        .and have_broadcasted_to(Realtime::Streams.cron_monitor(monitor_a)).once
        .and have_broadcasted_to(Realtime::Streams.cron_monitor(monitor_b)).once
    end

    it "la riga colpisce il dom_id del monitor; le pill arrivano da un refresh (CYRA-257)" do
      monitor = overdue_monitor

      expect { described_class.perform_now(now:) }
        .to have_broadcasted_to(crons_stream).with(a_string_including("crons_monitor_#{monitor.id}"))
        .and have_broadcasted_to(crons_stream).with(a_string_including(%(action="refresh")))
    end

    it "monitor scaduti in org diverse: ciascuno sul proprio stream, mai su quello altrui" do
      other_project = create(:project)
      overdue_monitor
      overdue_monitor(other_project)

      expect { described_class.perform_now(now:) }
        .to have_broadcasted_to(crons_stream).exactly(2).times                                     # 1 riga + 1 refresh
        .and have_broadcasted_to(Realtime::Streams.crons(other_project.organization)).exactly(2).times
    end

    it "nessun monitor scaduto: nessun broadcast" do
      create(:cron_monitor, project:, status: :ok, last_check_in_at: now - 10.minutes)

      expect { described_class.perform_now(now:) }.not_to have_broadcasted_to(crons_stream)
    end
  end
end
