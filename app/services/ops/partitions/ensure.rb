# frozen_string_literal: true

module Ops
  module Partitions
    # Prepara le fette che servono: quella di riserva, il mese in corso e i mesi in arrivo (CYRA-750).
    # Idempotente per costruzione (`IF NOT EXISTS` ovunque), quindi si può chiamare a ogni avvio, da
    # un giro ricorrente e dai comandi di preparazione del database senza contare le volte.
    #
    # Serve anche in prova e in sviluppo: `db/schema.rb` descrive la tabella padre ma NON le sue
    # fette, quindi un database appena caricato avrebbe soltanto il contenitore. Senza la fetta di
    # riserva la prima scrittura fallirebbe con «nessuna fetta per questa riga».
    class Ensure < ApplicationService
      def initialize(now: Time.current, tables: Ops::Partitions::TABLES)
        @now = now
        @tables = tables
      end

      # I nomi delle fette create in questo giro (vuoto = c'era già tutto).
      def call
        @tables.flat_map { |table| ensure_table(table) }
      end

      private

      def ensure_table(table)
        created = []
        created << ensure_default(table)
        months.each { |month| created << ensure_month(table, month) }
        created.compact
      end

      # Il mese in corso più i successivi. Non si creano fette all'indietro: un mese passato o esiste
      # già (l'ha fatto la migration o il giro di allora) oppure è vuoto, e crearlo servirebbe solo a
      # farlo cancellare la notte stessa.
      def months
        (0..Ops::Partitions::MONTHS_AHEAD).map { |offset| @now.utc.beginning_of_month + offset.months }
      end

      def ensure_default(table)
        create_partition(table, Ops::Partitions.default_partition_name(table.name), "DEFAULT")
      end

      def ensure_month(table, month)
        from, to = Ops::Partitions.bounds_for(month)
        create_partition(table, Ops::Partitions.partition_name(table.name, month),
                         "FOR VALUES FROM (#{connection.quote(sql_time(from))}) " \
                         "TO (#{connection.quote(sql_time(to))})")
      end

      # Due modi realistici di fallire, entrambi da non far pesare su chi sta avviando l'applicazione:
      # la fetta di riserva ha già righe di quel mese (il giro di manutenzione è mancato) e PostgreSQL
      # rifiuta di staccarle da sola; oppure due contenitori che partono insieme provano a crearla
      # nello stesso istante. Nel primo caso le righe sono salve e leggibili, restano solo dove non si
      # possono togliere in un istante; nel secondo l'ha già fatta l'altro. Sollevare vorrebbe dire
      # non far partire il servizio per un problema di spazio.
      def create_partition(table, name, bounds)
        return nil if partition_exists?(name)

        execute(<<~SQL.squish)
          CREATE TABLE IF NOT EXISTS #{quote_table(name)}
            PARTITION OF #{quote_table(table.name)} #{bounds}
        SQL
        ensure_natural_key_index(table, name)
        name
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("[partitions] fetta #{name} non creata: #{e.class}: #{e.message}")
        nil
      end

      # L'unicità della chiave naturale vive QUI, sulla singola fetta: sul padre PostgreSQL la
      # accetterebbe solo includendo la colonna del tempo, e con quella dentro una consegna ripetuta
      # non sarebbe più un duplicato. Vedi la nota in Ops::Partitions.
      def ensure_natural_key_index(table, partition_name)
        return if table.natural_key.blank?

        columns = table.natural_key.map { |c| connection.quote_column_name(c) }.join(", ")
        execute(<<~SQL.squish)
          CREATE UNIQUE INDEX IF NOT EXISTS #{connection.quote_column_name("#{partition_name}_natkey")}
            ON #{quote_table(partition_name)} (#{columns})
        SQL
      end

      # `::text` non è ornamentale: senza, il driver riceve un tipo che non conosce (`regclass`) e
      # lo annuncia con un avviso a ogni chiamata.
      def partition_exists?(name)
        connection.select_value("SELECT to_regclass(#{connection.quote(name)})::text").present?
      end

      def sql_time(time) = time.strftime("%Y-%m-%d %H:%M:%S")

      def quote_table(name) = connection.quote_table_name(name)

      def execute(sql) = connection.execute(sql)

      def connection = ApplicationRecord.connection
    end
  end
end
