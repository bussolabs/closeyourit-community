# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::PruneJob, type: :job do
  before { Settings::Global.instance.update!(servers_retention_days: 30) }

  it "gira sulla coda :batch dei lavori lunghi" do
    expect(described_class.new.queue_name).to eq("batch")
  end

  it "pota i sample oltre la retention di sistema e i container oltre 7 (costante fissa), preservando i recenti" do
    host = create(:server_host)
    old_sample = create(:server_sample, host: host, organization: host.organization, recorded_at: 31.days.ago)
    fresh_sample = create(:server_sample, host: host, organization: host.organization, recorded_at: 29.days.ago)
    old_container = create(:server_container_sample, host: host, recorded_at: 8.days.ago)
    fresh_container = create(:server_container_sample, host: host, recorded_at: 6.days.ago)

    described_class.perform_now

    expect(Servers::Sample.exists?(old_sample.id)).to be(false)
    expect(Servers::Sample.exists?(fresh_sample.id)).to be(true)
    expect(Servers::ContainerSample.exists?(old_container.id)).to be(false)
    expect(Servers::ContainerSample.exists?(fresh_container.id)).to be(true)
  end

  # CYRA-679 — i campioni in scadenza diventano medie orarie PRIMA del delete: la baseline
  # sopravvive alla retention raw. Idempotente: il bucket già scritto non si duplica sul retry.
  it "riduce a rollup orari i sample in scadenza prima di eliminarli" do
    host = create(:server_host)
    base = 31.days.ago.beginning_of_hour
    create(:server_sample, host: host, organization: host.organization,
           recorded_at: base + 5.minutes, cpu_pct: 10, data_volume_disk_pct: 40)
    create(:server_sample, host: host, organization: host.organization,
           recorded_at: base + 25.minutes, cpu_pct: 30, data_volume_disk_pct: 60)
    fresh = create(:server_sample, host: host, organization: host.organization, recorded_at: 1.day.ago)

    described_class.perform_now

    rollup = Servers::SampleRollup.find_by(host_id: host.id, bucket_at: base)
    expect(rollup.samples_count).to eq(2)
    expect(rollup.cpu_pct).to eq(20)
    expect(rollup.data_volume_disk_pct).to eq(50)
    expect(Servers::Sample.exists?(fresh.id)).to be(true)
    expect(Servers::SampleRollup.where(host_id: host.id).count).to eq(1)

    # Retry: nessun duplicato e il bucket non cambia.
    expect { described_class.perform_now }.not_to change(Servers::SampleRollup, :count)
  end

  # CYRA-1222 — a prune running mid-hour (03:07) must neither roll up nor delete the 03:00 hour:
  # a partial rollup would be frozen by ON CONFLICT DO NOTHING and the rest of the hour lost.
  describe "pruning in the middle of an hour" do
    let(:host) { create(:server_host) }
    let(:night) { Time.zone.local(2026, 11, 22, 3, 7) }
    let(:expiring_hour) { (night - 30.days).beginning_of_hour }

    def sample_at(time, cpu_pct: 10)
      create(:server_sample, host: host, organization: host.organization, recorded_at: time, cpu_pct: cpu_pct)
    end

    it "keeps the 03:00 hour intact and rolls it up whole the next night with all its 60 samples" do
      samples = (0..59).map { |minute| sample_at(expiring_hour + minute.minutes, cpu_pct: minute.even? ? 10 : 30) }

      travel_to(night) { described_class.perform_now }

      expect(Servers::SampleRollup.find_by(host_id: host.id, bucket_at: expiring_hour)).to be_nil
      expect(Servers::Sample.where(id: samples.map(&:id)).count).to eq(60)

      travel_to(night + 1.day) { described_class.perform_now }

      rollup = Servers::SampleRollup.find_by(host_id: host.id, bucket_at: expiring_hour)
      expect(rollup.samples_count).to eq(60)
      expect(rollup.cpu_pct).to eq(20)
      expect(rollup.net_sent_bytes).to eq(60 * 1024)
      expect(rollup.net_recv_bytes).to eq(60 * 2048)
      expect(Servers::Sample.where(id: samples.map(&:id))).to be_empty
      expect { travel_to(night + 1.day) { described_class.perform_now } }
        .not_to change { rollup.reload.attributes }
    end

    it "deletes only samples already counted in a written hourly rollup" do
      samples = [ 1, 2, 3 ].flat_map do |hours_before|
        [ 0, 15, 59 ].map { |minute| sample_at(expiring_hour - hours_before.hours + minute.minutes) }
      end
      samples += [ 0, 6, 7, 30 ].map { |minute| sample_at(expiring_hour + minute.minutes) }

      travel_to(night) { described_class.perform_now }

      deleted = samples.reject { |sample| Servers::Sample.exists?(sample.id) }
      expect(deleted.size).to eq(9)
      deleted.group_by { |sample| sample.recorded_at.beginning_of_hour }.each do |hour, in_hour|
        rollup = Servers::SampleRollup.find_by(host_id: host.id, bucket_at: hour)
        expect(rollup&.samples_count).to eq(in_hour.size)
      end
      expect(Servers::SampleRollup.where(host_id: host.id).count).to eq(3)
    end

    it "leaves a sample recorded exactly on the hour for the next night's full rollup" do
      on_the_hour = sample_at(expiring_hour)

      travel_to(night) { described_class.perform_now }

      expect(Servers::Sample.exists?(on_the_hour.id)).to be(true)
      expect(Servers::SampleRollup.find_by(host_id: host.id, bucket_at: expiring_hour)).to be_nil

      later = sample_at(expiring_hour + 45.minutes)
      travel_to(night + 1.day) { described_class.perform_now }

      expect(Servers::SampleRollup.find_by(host_id: host.id, bucket_at: expiring_hour).samples_count).to eq(2)
      expect(Servers::Sample.where(id: [ on_the_hour.id, later.id ])).to be_empty
    end

    it "uses the initial clock for every organization even when rollups take hours" do
      other = create(:server_host)
      other.organization.update!(servers_retention_days: 15)
      kept = sample_at(expiring_hour)
      other_cutoff = 15.days.ago(night).beginning_of_hour
      other_kept = create(:server_sample, host: other, recorded_at: other_cutoff)
      old = create(:server_sample, host: other, recorded_at: other_cutoff - 1.second)
      job = described_class.new
      allow(job).to receive(:rollup_expiring!).and_wrap_original do |original, *args|
        original.call(*args)
        travel_to(night + 2.hours)
      end

      travel_to(night) { job.perform_now }

      expect(Servers::Sample.where(id: [ kept.id, other_kept.id ]).count).to eq(2)
      expect(Servers::Sample.exists?(old.id)).to be(false)
      expect(Servers::SampleRollup.find_by(host_id: other.id)&.samples_count).to eq(1)
    end

    it "handles an organization without samples" do
      host
      travel_to(night) do
        expect { described_class.perform_now }.not_to change(Servers::SampleRollup, :count)
      end
    end

    it "preserves an existing rollup when older samples arrive later" do
      bucket = expiring_hour - 1.hour
      existing = Servers::SampleRollup.create!(
        host: host, organization: host.organization,
        bucket_at: bucket, samples_count: 2, cpu_pct: 20, net_sent_bytes: 100
      )
      sample_at(bucket + 5.minutes, cpu_pct: 90)

      expect { travel_to(night) { described_class.perform_now } }
        .not_to change { existing.reload.attributes }
    end

    [ "2026-03-29T03:07:00+02:00", "2026-10-25T02:07:00+02:00",
      "2026-10-25T02:07:00+01:00", "2026-03-30T03:07:00+02:00",
      "2026-10-26T02:07:00+01:00" ].each do |instant|
      it "preserves complete UTC buckets across the Rome clock change at #{instant}" do
        host.organization.update!(servers_retention_days: 1)
        start = Time.iso8601(instant).in_time_zone
        cutoff = 1.day.ago(start).beginning_of_hour
        old = sample_at(cutoff - 1.second)
        edge = sample_at(cutoff)
        later = sample_at(cutoff + 59.minutes, cpu_pct: 30)

        travel_to(start) { described_class.perform_now }

        expect(Servers::Sample.exists?(old.id)).to be(false)
        expect(Servers::Sample.where(id: [ edge.id, later.id ]).count).to eq(2)
        rollup = Servers::SampleRollup.find_by!(host_id: host.id)
        expect(rollup.bucket_at.utc).to eq((cutoff.utc - 1.hour).beginning_of_hour)
        expect(rollup.samples_count).to eq(1)

        travel_to(start + 2.days) { described_class.perform_now }

        complete = Servers::SampleRollup.find_by!(host_id: host.id, bucket_at: cutoff.utc)
        expect(complete.samples_count).to eq(2)
        expect(complete.cpu_pct).to eq(20)
        expect(complete.net_sent_bytes).to eq(2048)
        expect(Servers::Sample.where(id: [ edge.id, later.id ])).to be_empty
      end
    end

    it "aggregates the repeated Rome hour as two distinct complete UTC hours" do
      host.organization.update!(servers_retention_days: 1)
      first_hour = Time.utc(2026, 10, 25, 0)
      second_hour = Time.utc(2026, 10, 25, 1)
      samples = [ first_hour, second_hour ].flat_map do |hour|
        (0..59).map { |minute| sample_at(hour + minute.minutes, cpu_pct: hour == first_hour ? 10 : 30) }
      end

      travel_to(Time.zone.local(2026, 10, 26, 3, 7)) { described_class.perform_now }

      rollups = Servers::SampleRollup.where(host_id: host.id).order(:bucket_at)
      expect(rollups.pluck(:bucket_at)).to eq([ first_hour, second_hour ])
      expect(rollups.pluck(:samples_count)).to eq([ 60, 60 ])
      expect(rollups.pluck(:cpu_pct)).to eq([ 10, 30 ])
      expect(rollups.pluck(:net_sent_bytes)).to eq([ 60 * 1024, 60 * 1024 ])
      expect(rollups.pluck(:net_recv_bytes)).to eq([ 60 * 2048, 60 * 2048 ])
      expect(Servers::Sample.where(id: samples.map(&:id))).to be_empty
    end
  end

  it "pota i rollup oltre la retention lunga" do
    host = create(:server_host)
    old_rollup = Servers::SampleRollup.create!(
      host_id: host.id, organization_id: host.organization_id,
      bucket_at: (Servers::Constants::ROLLUP_RETENTION_DAYS + 1).days.ago, samples_count: 1
    )

    described_class.perform_now

    expect(Servers::SampleRollup.exists?(old_rollup.id)).to be(false)
  end

  it "rispetta l'override org-scoped (nearest-wins, niente livello progetto)" do
    org = create(:organization).tap { |o| o.update!(servers_retention_days: 15) }
    host = create(:server_host, organization: org)
    old_sample = create(:server_sample, host:, organization: org, recorded_at: 16.days.ago)
    fresh_sample = create(:server_sample, host:, organization: org, recorded_at: 10.days.ago)

    described_class.perform_now

    expect(Servers::Sample.exists?(old_sample.id)).to be(false)
    expect(Servers::Sample.exists?(fresh_sample.id)).to be(true)
  end

  it "non tocca i raw sample di un'altra org non configurata (default di sistema)" do
    other = create(:server_host)
    kept = create(:server_sample, host: other, organization: other.organization, recorded_at: 29.days.ago)

    org = create(:organization).tap { |o| o.update!(servers_retention_days: 15) }
    host = create(:server_host, organization: org)
    create(:server_sample, host:, organization: org, recorded_at: 16.days.ago)

    described_class.perform_now

    expect(Servers::Sample.exists?(kept.id)).to be(true)
  end

  it "pota le entries journald oltre 48h ai confini (±1s, costante fissa)" do
    host = create(:server_host)
    freeze_time do
      just_expired = create(:server_journal_entry, host: host, occurred_at: 48.hours.ago - 1.second)
      on_edge = create(:server_journal_entry, host: host, occurred_at: 48.hours.ago + 1.second)

      described_class.perform_now

      expect(Servers::Journal::Entry.exists?(just_expired.id)).to be(false)
      expect(Servers::Journal::Entry.exists?(on_edge.id)).to be(true)
    end
  end

  # CYRA-750 — l'ordine conta: la fetta si stacca DOPO il riepilogo orario. Al contrario si
  # butterebbe via la baseline di quel periodo, che è l'unica cosa che sopravvive ai campioni grezzi.
  describe "le fette scadute" do
    def crea_fetta(mese)
      nome = Ops::Partitions.partition_name("servers_samples", mese)
      da, a = Ops::Partitions.bounds_for(mese)
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        CREATE TABLE IF NOT EXISTS "#{nome}" PARTITION OF "servers_samples"
          FOR VALUES FROM ('#{da.strftime('%Y-%m-%d %H:%M:%S')}') TO ('#{a.strftime('%Y-%m-%d %H:%M:%S')}')
      SQL
      nome
    end

    it "protects processed retention windows when preferences shrink during rollup" do
      host = create(:server_host)
      host.organization.update!(servers_retention_days: 61)
      night = Time.zone.local(2026, 12, 1, 3, 7)
      partition = crea_fetta(Time.utc(2026, 10, 1))
      kept = create(:server_sample, host: host, recorded_at: Time.utc(2026, 10, 31, 23, 59))
      job = described_class.new
      allow(job).to receive(:rollup_expiring!).and_wrap_original do |original, *args|
        original.call(*args)
        host.organization.update!(servers_retention_days: 1)
      end

      travel_to(night) { job.perform_now }

      expect(ApplicationRecord.connection.select_value("SELECT to_regclass('#{partition}')::text")).to eq(partition)
      expect(Servers::Sample.exists?(kept.id)).to be(true)
      expect(Servers::SampleRollup.where(host_id: host.id)).to be_empty
    end

    it "does not cross a UTC month boundary when the clock advances during rollup" do
      host = create(:server_host)
      night = Time.zone.local(2026, 12, 1, 0, 57)
      partition = crea_fetta(Time.utc(2026, 10, 1))
      kept = create(:server_sample, host: host, recorded_at: Time.utc(2026, 10, 31, 23))
      old = create(:server_sample, host: host, recorded_at: Time.utc(2026, 10, 31, 22, 59))
      job = described_class.new
      allow(job).to receive(:rollup_expiring!).and_wrap_original do |original, *args|
        original.call(*args)
        travel_to(night + 2.hours)
      end

      travel_to(night) { job.perform_now }

      expect(ApplicationRecord.connection.select_value("SELECT to_regclass('#{partition}')::text")).to eq(partition)
      expect(Servers::Sample.exists?(kept.id)).to be(true)
      expect(Servers::Sample.exists?(old.id)).to be(false)
      expect(Servers::SampleRollup.find_by(host_id: host.id)&.samples_count).to eq(1)

      travel_to(night + 1.day) { described_class.perform_now }

      expect(ApplicationRecord.connection.select_value("SELECT to_regclass('#{partition}')::text")).to be_nil
      expect(Servers::SampleRollup.find_by(host_id: host.id, bucket_at: kept.recorded_at)&.samples_count).to eq(1)
    end

    it "stacca la fetta vecchia ma tiene le medie orarie di quel periodo" do
      host = create(:server_host)
      base = 10.months.ago.beginning_of_hour
      vecchia = crea_fetta(base)
      create(:server_sample, host: host, organization: host.organization, recorded_at: base + 5.minutes, cpu_pct: 40)

      described_class.perform_now

      esiste = ActiveRecord::Base.connection.select_value("SELECT to_regclass('#{vecchia}')::text")
      expect(esiste).to be_nil
      expect(Servers::SampleRollup.find_by(host_id: host.id, bucket_at: base)&.cpu_pct).to eq(40)
    end
  end
end
