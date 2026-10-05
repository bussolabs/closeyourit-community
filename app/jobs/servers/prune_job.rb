# frozen_string_literal: true

module Servers
  # Retention dei campioni di sistema: raw sample potati PER-ORGANIZZAZIONE (god → org, CYRA-159 — i
  # dati server sono org-scoped nel data model, niente livello progetto). Container (7g) e journal
  # (48h) restano buffer diagnostici a costante fissa (App::Constants). Daily (recurring.yml).
  # CYRA-679: prima del delete i campioni in scadenza vengono ridotti a medie orarie
  # (servers_sample_rollups, retention lunga a costante fissa) — la baseline sopravvive al raw;
  # i chart continuano ad aggregare il raw on-the-fly con date_bin.
  class PruneJob < ApplicationJob
    queue_as :batch

    def perform
      # Singleton god risolto UNA volta (non per-org) → niente N+1.
      global_days = Servers::Retention.resolve(Settings::Global.instance.servers_retention_days)

      # CYRA-750 — l'ordine qui NON è indifferente. Prima si riducono a medie orarie i campioni in
      # scadenza di OGNI organizzazione, poi si staccano le fette interamente fuori dalla finestra
      # più lunga in vigore, poi si pota il residuo riga per riga. Staccare una fetta prima del
      # riepilogo butterebbe via la baseline di quel periodo: il riepilogo legge i campioni grezzi,
      # e una fetta staccata non si rilegge.
      Organizations::Organization.find_each do |organization|
        days = Servers::Retention.for(organization, global_days: global_days)
        rollup_expiring!(organization.id, days.days.ago)
      end

      Ops::Partitions::DropExpired.call(table: "servers_samples",
                                        keep_from: Monitoring::Retention.longest(key: :servers, global_days: global_days).days.ago)

      Organizations::Organization.find_each do |organization|
        days = Servers::Retention.for(organization, global_days: global_days)
        Servers::Sample.where(organization_id: organization.id, recorded_at: ..days.days.ago)
                       .in_batches.delete_all
      end

      Servers::ContainerSample
        .where(recorded_at: ..Servers::Constants::CONTAINER_RETENTION_DAYS.days.ago)
        .in_batches.delete_all
      Servers::Journal::Entry
        .where(occurred_at: ..Servers::Constants::JOURNAL_RETENTION_HOURS.hours.ago)
        .in_batches.delete_all
      Servers::SampleRollup
        .where(bucket_at: ..Servers::Constants::ROLLUP_RETENTION_DAYS.days.ago)
        .in_batches.delete_all
    end

    private

    # UNA INSERT ... SELECT per organizzazione: aggrega in ore ESATTAMENTE le righe che il delete
    # subito dopo eliminerà. ON CONFLICT DO NOTHING = idempotente sul retry (il bucket già scritto
    # da un giro interrotto non si duplica e non si riscrive).
    def rollup_expiring!(organization_id, cutoff)
      conn = ApplicationRecord.connection
      conn.execute(<<~SQL)
        INSERT INTO servers_sample_rollups
          (host_id, organization_id, bucket_at, samples_count, cpu_pct, mem_pct, disk_pct,
           data_volume_disk_pct, inode_pct, temp_max, db_connections_max,
           net_sent_bytes, net_recv_bytes, created_at)
        SELECT host_id, organization_id, date_trunc('hour', recorded_at), COUNT(*),
               ROUND(AVG(cpu_pct), 2), ROUND(AVG(mem_pct), 2), ROUND(AVG(disk_pct), 2),
               ROUND(AVG(data_volume_disk_pct), 2), ROUND(AVG(inode_pct), 2),
               MAX(temp_max), MAX(db_connections),
               SUM(net_sent_bytes), SUM(net_recv_bytes), NOW()
        FROM servers_samples
        WHERE organization_id = #{conn.quote(organization_id)}
          AND recorded_at <= #{conn.quote(cutoff)}
        GROUP BY host_id, organization_id, date_trunc('hour', recorded_at)
        ON CONFLICT (host_id, bucket_at) DO NOTHING
      SQL
    end
  end
end
