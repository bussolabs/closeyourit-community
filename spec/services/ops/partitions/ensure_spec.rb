# frozen_string_literal: true

require "rails_helper"

# CYRA-750 — le fette non stanno in `db/schema.rb`: chi ricrea il database ottiene solo il
# contenitore, e senza queste creazioni la prima scrittura fallirebbe con «nessuna fetta per questa
# riga». Le creazioni fatte qui dentro tornano indietro col rollback della prova: in PostgreSQL
# anche il comando che crea una tabella sta dentro la transazione.
RSpec.describe Ops::Partitions::Ensure do
  def partizioni(tabella)
    ActiveRecord::Base.connection.select_values(<<~SQL.squish)
      SELECT child.relname
      FROM pg_catalog.pg_inherits i
        JOIN pg_catalog.pg_class parent ON i.inhparent = parent.oid
        JOIN pg_catalog.pg_class child ON i.inhrelid = child.oid
      WHERE parent.relname = '#{tabella}'
    SQL
  end

  def indici(tabella)
    ActiveRecord::Base.connection.select_values(
      "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename = '#{tabella}'"
    )
  end

  describe "le tabelle a fette" do
    it "sono cinque, tutte con la colonna del tempo d'arrivo come chiave di divisione" do
      chiavi = Ops::Partitions::TABLES.to_h { |t| [ t.name, t.key ] }

      expect(chiavi).to eq(
        "errors_events" => "created_at",
        "logs_entries" => "created_at",
        "metrics_samples" => "created_at",
        "analytics_pageviews" => "created_at",
        "servers_samples" => "recorded_at"
      )
    end

    it "sono divise davvero sul database, non solo nel catalogo dell'applicazione" do
      divise = ActiveRecord::Base.connection.select_values(<<~SQL.squish)
        SELECT relname FROM pg_class WHERE relkind = 'p' AND relname IN
          (#{Ops::Partitions.table_names.map { |n| "'#{n}'" }.join(', ')})
      SQL

      expect(divise).to match_array(Ops::Partitions.table_names)
    end
  end

  describe "le fette che prepara" do
    it "tiene pronto il mese in corso e quelli in arrivo" do
      described_class.call

      attese = (0..Ops::Partitions::MONTHS_AHEAD).map do |mesi|
        Ops::Partitions.partition_name("logs_entries", Time.current.utc.beginning_of_month + mesi.months)
      end

      expect(partizioni("logs_entries")).to include(*attese)
    end

    it "tiene una fetta di riserva, così una riga con un istante inatteso non fa fallire la scrittura" do
      described_class.call

      expect(partizioni("errors_events")).to include("errors_events_pdefault")
    end

    it "non ricrea quello che c'è già" do
      described_class.call

      expect(described_class.call).to be_empty
    end

    it "crea le fette del futuro quando arriva il loro momento" do
      fra_un_anno = 1.year.from_now

      create = described_class.call(now: fra_un_anno, tables: [ Ops::Partitions.table("logs_entries") ])

      expect(create).to include(Ops::Partitions.partition_name("logs_entries", fra_un_anno))
    end
  end

  describe "l'unicità della chiave naturale" do
    it "vive su ogni fetta, perché sul padre PostgreSQL la accetterebbe solo col tempo dentro" do
      described_class.call
      fetta = Ops::Partitions.partition_name("logs_entries", Time.current)

      expect(indici(fetta)).to include("#{fetta}_natkey")
    end

    it "non c'è per i campioni dei server, che l'hanno già sul padre e contiene l'istante" do
      described_class.call
      fetta = Ops::Partitions.partition_name("servers_samples", Time.current)

      expect(indici(fetta)).not_to include("#{fetta}_natkey")
    end
  end

  describe "quando la fetta non si può creare" do
    # Caso reale: il giro di manutenzione è mancato per settimane, le righe di quel mese sono finite
    # nella riserva e PostgreSQL rifiuta di staccarle da sola. Le righe restano leggibili e
    # scrivibili: far fallire l'avvio dell'applicazione sarebbe una reazione peggiore del problema.
    it "lascia un avviso nei log e va avanti invece di sollevare" do
      allow(ApplicationRecord.connection).to receive(:execute).and_call_original
      allow(ApplicationRecord.connection).to receive(:execute)
        .with(/CREATE TABLE IF NOT EXISTS "logs_entries_p2\d{3}_\d{2}"/)
        .and_raise(ActiveRecord::StatementInvalid, "updated partition constraint")
      allow(Rails.logger).to receive(:warn)

      esito = described_class.call(now: 1.year.from_now, tables: [ Ops::Partitions.table("logs_entries") ])

      expect(esito).to be_empty
      expect(Rails.logger).to have_received(:warn).with(/logs_entries_p/).at_least(:once)
    end
  end
end
