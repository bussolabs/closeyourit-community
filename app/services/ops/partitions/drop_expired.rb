# frozen_string_literal: true

module Ops
  module Partitions
    # Stacca le fette interamente scadute (CYRA-750): un `DROP TABLE` per fetta, costo costante,
    # spazio restituito subito al filesystem invece che lasciato come tuple morte da ripassare.
    #
    # `keep_from` è la finestra di conservazione PIÙ LUNGA in vigore, non quella del singolo cliente:
    # una fetta contiene le righe di TUTTI i progetti, quindi si può staccare solo quando nessuno ha
    # più diritto a niente di ciò che c'è dentro. Chi conserva meno continua a essere potato riga per
    # riga dai giri di sempre — che così lavorano sul residuo, non sull'archivio intero.
    #
    # La fetta di riserva non scade mai: non porta un mese nel nome, quindi non entra nel confronto.
    #
    # Staccare una fetta chiude per un istante l'intera tabella (PostgreSQL prende il lucchetto più
    # forte sul padre per riscrivere l'elenco delle fette). È un istante perché non si legge nessuna
    # riga — ma è la ragione per cui questo gira dentro la potatura notturna e non a orario di punta.
    class DropExpired < ApplicationService
      def initialize(table:, keep_from:)
        @table = Ops::Partitions.table(table)
        @keep_from = keep_from
      end

      # I nomi delle fette staccate (vuoto = nessuna era interamente scaduta).
      def call
        return [] if @keep_from.blank?

        expired.each { |name| connection.execute("DROP TABLE IF EXISTS #{connection.quote_table_name(name)}") }
      end

      private

      # Una fetta scade quando il suo estremo SUPERIORE è già oltre la finestra: il confronto è sul
      # limite alto proprio perché l'ultima riga della fetta deve essere scaduta anche lei. Il mese
      # si legge dal nome, che è l'unica cosa che questo servizio e Ensure si scambiano.
      def expired
        pattern = Ops::Partitions.monthly_pattern(@table.name)
        partitions.filter_map do |name|
          match = pattern.match(name)
          next unless match

          upper_bound = Time.utc(match[1].to_i, match[2].to_i).next_month
          name if upper_bound <= @keep_from
        end
      end

      def partitions
        connection.select_values(<<~SQL.squish)
          SELECT child.relname
          FROM pg_catalog.pg_inherits i
            JOIN pg_catalog.pg_class parent ON i.inhparent = parent.oid
            JOIN pg_catalog.pg_class child ON i.inhrelid = child.oid
          WHERE parent.relname = #{connection.quote(@table.name)}
        SQL
      end

      def connection = ApplicationRecord.connection
    end
  end
end
