# frozen_string_literal: true

require "rails_helper"

# Broadcast realtime di Crons::RecordCheckIn. Dopo il commit (check-in + update monitor):
#  - stream crons dell'org  → replace riga monitor (target dom_id(monitor)) + replace pill (target crons_stats)
#  - stream del monitor     → prepend nuovo check-in (target cron_monitor_check_ins_<id>)
#                             + replace header di stato (target cron_monitor_labels_<id>)
# Gli stream sono org-prefissati da Realtime::Streams → l'isolamento tenant è implicito nel nome-stream.
# (have_broadcasted_to su stream String legge il broadcast Turbo grezzo, niente .from_channel.)
RSpec.describe Crons::RecordCheckIn, "broadcasts", type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:crons_stream) { Realtime::Streams.crons(organization) }
  let(:project_stream) { Realtime::Streams.project_crons(project) }

  def record(slug: "nightly") = described_class.call(project:, slug:)

  describe "list streams" do
    it "replaces the monitor row on the PROJECT stream, with target dom_id(monitor)" do
      record   # the monitor is born at the first check-in
      monitor = project.cron_monitors.sole

      expect { record }.to have_broadcasted_to(project_stream).once
        .with(a_string_including("crons_monitor_#{monitor.id}"))
    end

    # The rendered row must not travel on the org stream: there it reached viewers who cannot see
    # the project (CYRA-1040). The org stream carries only the refresh for the pills (CYRA-257).
    it "sends only a refresh on the org stream, never rendered HTML" do
      seen = []
      expect { record }.to have_broadcasted_to(crons_stream).once.with { |html| seen << html }

      expect(seen).to include(a_string_including(%(action="refresh")))
      expect(seen.join).not_to include("crons_monitor_")
      expect(seen.join).not_to include("crons_stats")
    end
  end

  describe "stream del monitor (show)" do
    it "prepend del check-in + replace dell'header di stato" do
      record
      monitor = project.cron_monitors.sole
      monitor_stream = Realtime::Streams.cron_monitor(monitor)

      expect { record }.to have_broadcasted_to(monitor_stream)
        .with(a_string_including("cron_monitor_check_ins_#{monitor.id}"))
      expect { record }.to have_broadcasted_to(monitor_stream)
        .with(a_string_including("cron_monitor_labels_#{monitor.id}"))
    end

    it "recovery missed→ok: la riga broadcastata riflette lo stato fresco" do
      record
      monitor = project.cron_monitors.sole
      monitor.update!(status: :missed, missed_alerted_at: Time.current)

      expect { record }.to have_broadcasted_to(project_stream)
        .with(a_string_including("crons_monitor_#{monitor.id}"))
      expect(monitor.reload).to be_status_ok
    end
  end

  describe "errori (nessun broadcast)" do
    it "slug blank → nessun broadcast" do
      expect { described_class.call(project:, slug: "  ") }.not_to have_broadcasted_to(crons_stream)
    end
  end

  it "registra i broadcast dopo il commit della transazione più esterna" do
    allow(ActiveRecord).to receive(:after_all_transactions_commit)

    expect(Crons::Broadcast).not_to receive(:row)
    record
  end

  it "non trasmette un check-in stantio fuori ordine" do
    newer_at = Time.utc(2026, 7, 13, 20, 2)
    described_class.call(project:, slug: "nightly", at: newer_at)
    allow(ActiveRecord).to receive(:after_all_transactions_commit).and_yield

    expect(Crons::Broadcast).not_to receive(:check_in)
    described_class.call(project:, slug: "nightly", at: newer_at - 1.minute)
  end

  it "serializza callback after-commit invertite e trasmette solo lo snapshot persistito più recente" do
    older_at = Time.utc(2026, 7, 13, 20, 1)
    newer_at = older_at + 1.minute
    callbacks = []
    allow(ActiveRecord).to receive(:after_all_transactions_commit) { |&callback| callbacks << callback }
    allow(Crons::Broadcast).to receive_messages(row: nil, stats: nil, labels: nil)

    described_class.call(project:, slug: "nightly", at: older_at)
    described_class.call(project:, slug: "nightly", at: newer_at)

    expect(Crons::Broadcast).to receive(:check_in).once.with(
      anything, have_attributes(checked_in_at: newer_at)
    )
    callbacks.reverse_each(&:call)
  end

  describe "isolamento tenant" do
    it "non broadcasta sullo stream crons di un'ALTRA organizzazione" do
      other = Realtime::Streams.crons(create(:organization))
      expect { record }.not_to have_broadcasted_to(other)
    end

    it "does not broadcast the row on the stream of ANOTHER project of the same organization" do
      other = Realtime::Streams.project_crons(create(:project, organization:))
      expect { record }.not_to have_broadcasted_to(other)
    end
  end
end
