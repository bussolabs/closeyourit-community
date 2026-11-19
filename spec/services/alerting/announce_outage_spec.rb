# frozen_string_literal: true

require "rails_helper"

# CYRA-1228 — il punto unico che accoda l'avviso di fermo e ne scrive il segno, per il controllo e per
# il giro di recupero.
RSpec.describe Alerting::AnnounceOutage, type: :service do
  describe "server giù" do
    it "accoda server_down e scrive il segno" do
      host = create(:server_host, :down, last_push_at: 10.minutes.ago)

      expect { described_class.call(subject: host) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "server_down", subject_type: "Servers::Host", subject_id: host.id,
                             organization_id: host.organization_id, project_id: nil))
      expect(host.reload.down_alerted_at).to be_present
    end

    it "il secondo esecutore trova il segno e non accoda niente" do
      host = create(:server_host, :down, last_push_at: 10.minutes.ago)
      expect(described_class.call(subject: host).value).to be(true)

      expect { expect(described_class.call(subject: host).value).to be(false) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "rilegge la riga: una macchina tornata su intanto non si annuncia" do
      host = create(:server_host, :down, last_push_at: 10.minutes.ago)
      Servers::Host.where(id: host.id).update_all(status: Servers::Host.statuses[:up])

      expect { described_class.call(subject: host) }.not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(host.reload.down_alerted_at).to be_nil
    end

    it "un accodamento che fallisce lascia il segno vuoto: il recupero riprova" do
      host = create(:server_host, :down, last_push_at: 10.minutes.ago)
      allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(StandardError, "coda giù")

      expect { described_class.call(subject: host) }.to raise_error(StandardError, "coda giù")
      expect(host.reload.down_alerted_at).to be_nil
    end
  end

  describe "cluster giù" do
    it "accoda cluster_down e scrive il segno" do
      cluster = create(:cluster, status: :down, last_snapshot_at: 10.minutes.ago)

      expect { described_class.call(subject: cluster) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "cluster_down", subject_type: "Clusters::Cluster",
                             subject_id: cluster.id, organization_id: cluster.organization_id))
      expect(cluster.reload.down_alerted_at).to be_present
    end
  end

  # La transizione stessa sta sotto lock: due esecutori che hanno caricato la riga ancora up/ok non
  # possono dichiarare il fermo due volte (il secondo azzerava il segno del primo e riaccodava).
  describe ".declare" do
    it "server: due istanze caricate prima, un solo fermo e un solo avviso" do
      host = create(:server_host, status: :up, last_push_at: 10.minutes.ago)
      first = Servers::Host.find(host.id)
      second = Servers::Host.find(host.id)

      expect { expect(described_class.declare(subject: first).value).to be(true) }
        .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "server_down")).once
      mark = host.reload.down_alerted_at
      expect(first).to be_status_down

      expect { expect(described_class.declare(subject: second).value).to be(false) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(host.reload.down_alerted_at).to eq(mark)
    end

    it "cluster: il secondo esecutore non azzera il segno" do
      cluster = create(:cluster, status: :up, last_snapshot_at: 10.minutes.ago)
      first = Clusters::Cluster.find(cluster.id)
      second = Clusters::Cluster.find(cluster.id)

      described_class.declare(subject: first)
      mark = cluster.reload.down_alerted_at

      expect { expect(described_class.declare(subject: second).value).to be(false) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(cluster.reload.down_alerted_at).to eq(mark)
    end

    it "lavoro pianificato: il secondo esecutore non azzera il segno" do
      monitor = create(:cron_monitor, status: :ok, expected_interval_minutes: 60, grace_minutes: 5,
                                      last_check_in_at: 2.hours.ago)
      first = Crons::Monitor.find(monitor.id)
      second = Crons::Monitor.find(monitor.id)

      described_class.declare(subject: first)
      mark = monitor.reload.missed_alerted_at
      expect(mark).to be_present

      expect { expect(described_class.declare(subject: second).value).to be(false) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(monitor.reload.missed_alerted_at).to eq(mark)
    end

    it "una macchina tornata su dopo il caricamento non si dichiara giù" do
      host = create(:server_host, status: :up, last_push_at: 10.minutes.ago)
      loaded = Servers::Host.find(host.id)
      Servers::Host.where(id: host.id).update_all(last_push_at: Time.current)

      expect { expect(described_class.declare(subject: loaded).value).to be(false) }
        .not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(host.reload).to be_status_up
    end

    it "un accodamento che fallisce lascia il fermo scritto col segno vuoto" do
      host = create(:server_host, status: :up, last_push_at: 10.minutes.ago)
      allow(Alerting::EvaluateJob).to receive(:perform_later).and_raise(StandardError, "coda giù")

      expect { described_class.declare(subject: host) }.to raise_error(StandardError, "coda giù")
      expect(host.reload).to be_status_down
      expect(host.down_alerted_at).to be_nil
    end
  end

  describe "lavoro pianificato mancato" do
    it "accoda cron_missed e scrive il segno all'ora indicata" do
      at = Time.current.change(usec: 0)
      monitor = create(:cron_monitor, status: :missed, last_check_in_at: 2.hours.ago)

      expect { described_class.call(subject: monitor, at:) }
        .to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(event_type: "cron_missed", subject_type: "Crons::Monitor", subject_id: monitor.id,
                             project_id: monitor.project_id, environment_id: monitor.environment_id))
      expect(monitor.reload.missed_alerted_at).to be_within(1).of(at)
    end

    it "un lavoro che ha già risposto non si annuncia" do
      monitor = create(:cron_monitor, status: :ok, last_check_in_at: 1.minute.ago)

      expect { described_class.call(subject: monitor) }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end
end
