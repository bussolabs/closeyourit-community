# frozen_string_literal: true

require "rails_helper"

# CYRA-749 — sulle tabelle che ricevono più dati (occorrenze di errore, log, campioni di metrica,
# web vitals, campioni di server e di container) un indice su UNA colonna sola non aggiunge niente
# quando esiste già un indice composito che comincia con quella stessa colonna: PostgreSQL sa usare
# il PREFISSO di un B-tree composito per una condizione sulla sola prima colonna.
#
# Non aggiunge niente in lettura, ma si paga a ogni scrittura: ogni INSERT aggiorna TUTTI gli indici
# della tabella, e queste sono le tabelle dove gli INSERT arrivano a raffica dall'ingest. È il caso
# in cui un indice inutile non è neutro — è il costo fisso di ogni riga che entra.
#
# Questa prova presidia due cose insieme, e serve la seconda perché la prima da sola è pericolosa:
#
#   1. che sulle tabelle ad alta scrittura non ricompaia un indice a colonna sola già coperto dal
#      prefisso di un composito (basta un `t.references ..., index: true` di troppo);
#   2. che le colonne rimaste senza indice proprio siano ANCORA raggiungibili da un indice, cioè che
#      il composito che le copre non venga tolto o riordinato in un secondo momento. Senza questa
#      metà, il giorno in cui qualcuno cambia l'ordine delle colonne di un composito la lettura per
#      progetto diventa una scansione dell'intera storia e nessuno se ne accorge fino a produzione.
RSpec.describe "Gli indici doppi sulle tabelle che ricevono più dati", type: :model do
  # Le tabelle scritte dall'ingest, quelle dove il costo di un indice in più si paga a ogni riga.
  let(:tabelle_ad_alta_scrittura) do
    %w[
      errors_events
      logs_entries
      metrics_samples
      analytics_web_vitals
      servers_samples
      servers_container_samples
    ]
  end

  # Le colonne che hanno perso l'indice tutto loro e ora si appoggiano al prefisso di un composito.
  let(:colonne_senza_indice_proprio) do
    {
      "errors_events" => %w[group_id project_id],
      "logs_entries" => %w[project_id],
      "metrics_samples" => %w[group_id project_id],
      "analytics_web_vitals" => %w[project_id],
      "servers_samples" => %w[host_id],
      "servers_container_samples" => %w[host_id]
    }
  end

  let(:connection) { ActiveRecord::Base.connection }

  # Un indice a colonna sola è ridondante solo se NON è unico (un unico è anche un vincolo, e toglierlo
  # cambierebbe cosa il database accetta) e NON è parziale (copre meno righe, quindi ha un suo compito).
  def indici_a_colonna_sola(table)
    connection.indexes(table).select do |index|
      index.columns.is_a?(Array) && index.columns.size == 1 && !index.unique && index.where.blank?
    end
  end

  def composito_che_comincia_con(table, column)
    connection.indexes(table).find do |index|
      index.columns.is_a?(Array) && index.columns.size > 1 && index.columns.first == column && index.where.blank?
    end
  end

  describe "non esistono più" do
    it "nessuna tabella ad alta scrittura ha un indice a colonna sola già coperto da un composito" do
      doppi = tabelle_ad_alta_scrittura.flat_map do |table|
        indici_a_colonna_sola(table).filter_map do |index|
          copertura = composito_che_comincia_con(table, index.columns.first)
          next if copertura.nil?

          "#{table}.#{index.name} (#{index.columns.first}) — già coperto da " \
            "#{copertura.name} [#{copertura.columns.join(', ')}]"
        end
      end

      expect(doppi).to be_empty, <<~MESSAGGIO
        Questi indici non servono a nessuna lettura e si pagano a ogni scrittura:

        #{doppi.join("\n")}

        Il prefisso del composito copre già la stessa condizione. Toglili con una migration
        (DROP INDEX CONCURRENTLY, come 20260902180000_drop_redundant_single_column_indexes).
      MESSAGGIO
    end
  end

  describe "le letture restano veloci" do
    # `enable_seqscan = off` non VIETA la scansione completa: la rende costosissima, così il
    # pianificatore sceglie un indice se ne ha uno utilizzabile. Su una tabella di prova quasi vuota
    # è l'unico modo onesto di chiedere «esiste ancora una strada che passa da un indice?»: con poche
    # righe la scansione completa è davvero la scelta migliore e il piano non direbbe niente.
    # `SET LOCAL` muore con la transazione della prova e non sporca le altre.
    def piano_di_lettura(table, column)
      connection.execute("SET LOCAL enable_seqscan = off")
      connection.select_values(
        "EXPLAIN SELECT id FROM #{table} WHERE #{column} = #{connection.quote(SecureRandom.uuid)}::uuid"
      ).join("\n")
    end

    it "ogni colonna rimasta senza indice proprio è ancora servita dal prefisso di un composito" do
      colonne_senza_indice_proprio.each do |table, columns|
        columns.each do |column|
          copertura = composito_che_comincia_con(table, column)

          expect(copertura).to be_present,
                               "#{table}.#{column} non ha più nessun indice: né uno suo, né un composito " \
                               "che cominci con lei. Ogni lettura per quella colonna scandisce tutta la tabella."
        end
      end
    end

    it "il pianificatore sceglie davvero un indice per una lettura sulla sola colonna" do
      colonne_senza_indice_proprio.each do |table, columns|
        columns.each do |column|
          expect(piano_di_lettura(table, column)).to match(/Index Scan|Index Only Scan|Bitmap Index Scan/),
                                                     "la lettura di #{table} per #{column} non passa da nessun indice"
        end
      end
    end
  end
end
