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
