# frozen_string_literal: true

require "rails_helper"

# CYRA-1228 — il recupero degli avvisi di fermo rimasti senza segno: il controllo ha cambiato lo stato
# e il processo è caduto prima di accodare l'avviso. Il controllo non riguarda più chi è già giù,
# quindi senza questo giro l'avviso è perso per sempre.
RSpec.describe Alerting::ReconcileOutages, type: :service do
  let(:host_threshold) { Servers::Constants::STALE_AFTER_SECONDS.seconds }
  let(:cluster_threshold) { Clusters::Constants::STALE_AFTER_SECONDS.seconds }

  describe "server" do
    it "consegna il fermo mai annunciato una volta sola" do
      host = create(:server_host, :down, last_push_at: host_threshold.ago - 10.minutes)

      expect { described_class.call }.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_down", subject_id: host.id)).once
      expect(host.reload.down_alerted_at).to be_present

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "non tocca il fermo appena segnato: la consegna normale è ancora in corso" do
      create(:server_host, :down, last_push_at: host_threshold.ago - 30.seconds)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "lascia stare i fermi più vecchi della finestra" do
      create(:server_host, :down, last_push_at: 2.days.ago)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "non ripassa un fermo già annunciato (anche quelli marcati al rilascio)" do
      create(:server_host, :down, last_push_at: host_threshold.ago - 10.minutes, down_alerted_at: 1.minute.ago)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "non annuncia una macchina tornata su, in pausa o revocata" do
      create(:server_host, :up, last_push_at: host_threshold.ago - 10.minutes)
      create(:server_host, :paused, last_push_at: host_threshold.ago - 10.minutes)
      create(:server_host, :down, :revoked, last_push_at: host_threshold.ago - 10.minutes)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe "cluster" do
    it "consegna il fermo mai annunciato" do
      cluster = create(:cluster, status: :down, last_snapshot_at: cluster_threshold.ago - 10.minutes)

      expect { described_class.call }.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "cluster_down", subject_id: cluster.id))
      expect(cluster.reload.down_alerted_at).to be_present
    end

    it "non annuncia un cluster tornato su" do
      create(:cluster, status: :up, last_snapshot_at: cluster_threshold.ago - 10.minutes)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe "lavori pianificati" do
    it "consegna il mancato mai annunciato" do
      monitor = create(:cron_monitor, status: :missed, expected_interval_minutes: 60, grace_minutes: 5,
                                      last_check_in_at: 75.minutes.ago)

      expect { described_class.call }.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "cron_missed", subject_id: monitor.id))
      expect(monitor.reload.missed_alerted_at).to be_present
    end

    it "non tocca il mancato appena scaduto" do
      create(:cron_monitor, status: :missed, expected_interval_minutes: 60, grace_minutes: 5,
                            last_check_in_at: 65.minutes.ago - 30.seconds)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "ignora un lavoro che ha risposto o che è stato disattivato" do
      create(:cron_monitor, status: :ok, last_check_in_at: 75.minutes.ago)
      create(:cron_monitor, status: :missed, enabled: false, last_check_in_at: 75.minutes.ago)

      expect { described_class.call }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  it "conta gli avvisi recuperati" do
    create(:server_host, :down, last_push_at: host_threshold.ago - 10.minutes)
    create(:cluster, status: :down, last_snapshot_at: cluster_threshold.ago - 10.minutes)

    expect(described_class.call.value).to eq(2)
  end

  it "una riga che esplode non si porta dietro le altre: resta pendente per il giro dopo" do
    host = create(:server_host, :down, last_push_at: host_threshold.ago - 10.minutes)
    allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(StandardError, "coda giù")

    expect(described_class.call.value).to eq(0)
    expect(host.reload.down_alerted_at).to be_nil
  end
end
